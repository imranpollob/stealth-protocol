// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {ISemaphoreVerifier} from "@semaphore-protocol/contracts/interfaces/ISemaphoreVerifier.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {NullifierLogic} from "./lib/NullifierLogic.sol";

/// @title CreditPaymaster
/// @notice ERC-4337 v0.7 paymaster that sponsors arbitrary transactions for any
///         sender, authenticated by a Semaphore v4 ZK membership proof.
///
///         Privacy property: the credit-earning address (which deposited into
///         CreditPool) and the credit-spending address (userOp.sender) need not
///         be related. Observers cannot link the two — the ZK proof reveals only
///         a nullifier, not the depositor's identity or commitment leaf.
///
///         Proof structure (Semaphore v4 SemaphoreProof):
///           merkleTreeDepth  — depth of the LeanIMT at proof time
///           merkleTreeRoot   — must match _merkleRoot (mirrored from CreditPool)
///           nullifier        — Poseidon(identity_nullifier, scope) revealed on-chain
///           message          — userOpHash cast to uint256 (binds proof to this op)
///           scope            — userOpHash cast to uint256 (external nullifier;
///                              scopes nullifier to this specific UserOperation hash,
///                              preventing replay and front-running)
///           points[8]        — Groth16 proof (pA, pB, pC packed as 8 uint256)
///
///         paymasterAndData layout (ERC-4337 v0.7):
///           [0:20]   paymaster address
///           [20:36]  paymasterVerificationGasLimit (uint128)
///           [36:52]  paymasterPostOpGasLimit (uint128)
///           [52:]    abi.encode(SemaphoreProof) — the actual proof data
///
///         ERC-7562 compliance:
///           - validatePaymasterUserOp reads only _merkleRoot and _nullifiers (own storage).
///           - Merkle root is pushed here by CreditPool.deposit() via mirrorRoot().
///           - verifyProof() is a pure-computation precompile call — ERC-7562 allows it.
///           - No banned opcodes (TIMESTAMP, NUMBER, ORIGIN, BASEFEE, etc.) in validation.
///           - This contract must be staked at the EntryPoint before going live.
///
///         Gas cap:
///           MAX_CREDIT_GAS enforces the sybil-resistance invariant's c_credit bound as
///           fixed gas units, independent of ETH/gas-price at spend time. Set this to
///           the measured worst-case gas for a typical sponsored transaction after M8.
contract CreditPaymaster is IPaymaster {
    using UserOperationLib for PackedUserOperation;
    using NullifierLogic for mapping(uint256 => bool);

    // ── Sybil-resistance invariant ───────────────────────────────────────────
    // V_MIN > c_ann + kappa * c_credit
    // c_credit is denominated in gas units (not ETH) so the invariant is
    // immune to gas-price volatility between Bootstrap and spend phases.
    // Set after gas measurement in M8; placeholder 500 000 is conservative.
    uint256 public constant MAX_CREDIT_GAS = 500_000;

    address public immutable entryPoint;
    address public immutable creditPool; // only caller allowed for mirrorRoot

    ISemaphoreVerifier public immutable verifier;

    // Mirrored Merkle root (pushed from CreditPool — own storage, ERC-7562 compliant)
    uint256 private _merkleRoot;

    // Spent nullifiers
    mapping(uint256 => bool) private _nullifiers;

    error NotEntryPoint();
    error NotCreditPool();
    error InvalidProof();
    error NullifierSpent(uint256 nullifier);
    error GasCapExceeded(uint256 requested, uint256 cap);
    error RootMismatch(uint256 proofRoot, uint256 storedRoot);
    error WrongScope();
    error WrongMessage();

    event RootMirrored(uint256 indexed newRoot);
    event CreditSpent(uint256 indexed nullifier, address indexed sender);

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    /// @param _entryPoint   ERC-4337 v0.7 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
    /// @param _creditPool   CreditPool address
    /// @param _verifier     SemaphoreVerifier contract
    constructor(address _entryPoint, address _creditPool, address _verifier) {
        entryPoint = _entryPoint;
        creditPool = _creditPool;
        verifier = ISemaphoreVerifier(_verifier);
    }

    /// @notice Called by CreditPool.deposit() after each insertion to keep the
    ///         mirrored root in sync. This is the mirror-and-stake write path.
    function mirrorRoot(uint256 newRoot) external {
        if (msg.sender != creditPool) revert NotCreditPool();
        _merkleRoot = newRoot;
        emit RootMirrored(newRoot);
    }

    /// @notice ERC-4337 paymaster validation. Reads only own storage (_merkleRoot, _nullifiers).
    ///         Accepts any sender — the ZK proof is the sole authentication mechanism.
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 /* maxCost */
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // ── 1. Enforce gas cap (c_credit bound in fixed gas units) ──────────
        // accountGasLimits = uint128(verificationGasLimit) || uint128(callGasLimit)
        uint256 callGas = userOp.unpackCallGasLimit();
        uint256 verifyGas = userOp.unpackVerificationGasLimit();
        if (callGas + verifyGas > MAX_CREDIT_GAS) {
            revert GasCapExceeded(callGas + verifyGas, MAX_CREDIT_GAS);
        }

        // ── 2. Decode proof from paymasterData (offset 52, per ERC-4337 v0.7) ──
        // paymasterAndData = address(20) || verGasLimit(16) || postOpGasLimit(16) || proofBytes
        bytes calldata proofBytes = userOp.paymasterAndData[UserOperationLib.PAYMASTER_DATA_OFFSET:];
        ISemaphore.SemaphoreProof memory proof = abi.decode(proofBytes, (ISemaphore.SemaphoreProof));

        // ── 3. Check merkle root (own storage only — ERC-7562 compliant) ────
        if (proof.merkleTreeRoot != _merkleRoot) {
            revert RootMismatch(proof.merkleTreeRoot, _merkleRoot);
        }

        // ── 4. Bind proof to this exact UserOperation (scope = externalNullifier) ──
        // Both scope and message carry userOpHash so an observer cannot reuse
        // a valid proof for a different UserOperation or a different scope.
        uint256 uopHashUint = uint256(userOpHash);
        if (proof.scope != uopHashUint) revert WrongScope();
        if (proof.message != uopHashUint) revert WrongMessage();

        // ── 5. Replay check (own storage) ───────────────────────────────────
        if (_nullifiers.isSpent(proof.nullifier)) revert NullifierSpent(proof.nullifier);

        // ── 6. ZK proof verification (pure computation — ERC-7562 allows) ───
        // Semaphore v4 hashes message and scope through keccak >> 8 before
        // embedding in public signals. Replicate that here.
        bool valid = verifier.verifyProof(
            [proof.points[0], proof.points[1]],
            [[proof.points[2], proof.points[3]], [proof.points[4], proof.points[5]]],
            [proof.points[6], proof.points[7]],
            [
                proof.merkleTreeRoot,
                proof.nullifier,
                _hashForCircuit(proof.message),
                _hashForCircuit(proof.scope)
            ],
            proof.merkleTreeDepth
        );
        if (!valid) revert InvalidProof();

        // ── 7. Mark nullifier spent ──────────────────────────────────────────
        _nullifiers[proof.nullifier] = true;

        emit CreditSpent(proof.nullifier, userOp.sender);

        // Empty context — postOp not required.
        return ("", 0);
    }

    /// @dev Required by IPaymaster. Not called when context is empty.
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {}

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Matches Semaphore.sol's _hash(): keccak256(abi.encodePacked(x)) >> 8.
    ///      Required so public signals in the circuit match what we pass to verifyProof.
    function _hashForCircuit(uint256 x) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(x))) >> 8;
    }

    // ── View helpers ─────────────────────────────────────────────────────────

    function merkleRoot() external view returns (uint256) {
        return _merkleRoot;
    }

    function isNullifierSpent(uint256 nullifier) external view returns (bool) {
        return _nullifiers[nullifier];
    }
}
