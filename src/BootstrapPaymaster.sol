// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {EligibilityLogic} from "./lib/EligibilityLogic.sol";

/// @title BootstrapPaymaster
/// @notice ERC-4337 v0.7 paymaster that sponsors exactly ONE transaction per
///         eligible stealth address: the CreditPool.deposit(commitment) call.
///
///         ERC-7562 compliance:
///         - validatePaymasterUserOp reads ONLY this contract's own storage
///           (_eligible, _used). Eligibility data is pushed here from
///           AnnouncementRegistry via mirrorEligible() — no external SLOADs.
///         - Banned opcodes (TIMESTAMP, NUMBER, ORIGIN, BASEFEE, etc.) are
///           not used anywhere in the validation path.
///         - This contract must be staked at the EntryPoint before going live.
///
///         Sybil-resistance: sponsoring only CreditPool.deposit means an
///         attacker who self-announces gets exactly one free deposit tx —
///         they still must fund a stealth address with >= vMin ETH first.
contract BootstrapPaymaster is IPaymaster {
    using UserOperationLib for PackedUserOperation;

    // ── Sponsorship budget ───────────────────────────────────────────────────
    /// @notice Absolute budget for one bootstrap sponsorship, in wei.
    ///         Mirrors CreditPaymaster.MAX_SPONSORSHIP_COST so that the total
    ///         sponsored exposure of one credit is bounded by
    ///           c_credit * p_max = c_boot * p_max + c_spend * p_max
    ///                            = 0.005 ETH + 0.005 ETH = 0.01 ETH,
    ///         which is what the Sybil-resistance invariant
    ///           F > kappa * c_credit * p_max
    ///         is stated against (kappa = 2, F = 0.021 ETH).
    ///
    ///         Checked against the EntryPoint's own requiredPrefund rather than
    ///         gas-field proxies: requiredPrefund covers verificationGasLimit +
    ///         callGasLimit + paymasterVerificationGasLimit + paymasterPostOpGasLimit
    ///         + preVerificationGas, so a per-field cap would leave the account's
    ///         attacker-controlled verification phase unbounded.
    uint256 public constant MAX_BOOTSTRAP_SPONSORSHIP_COST = 0.005 ether;

    /// @notice p_max — the highest gas price this paymaster will sponsor at.
    ///         Without it, actualGasCost = actualGas * min(maxFeePerGas, basefee +
    ///         maxPriorityFeePerGas) is unbounded, and a self-bundling caller is
    ///         the beneficiary of that payment.
    uint256 public constant MAX_ACCEPTED_MAX_FEE_PER_GAS = 10 gwei;

    /// @dev `execute(address,uint256,bytes)` — the single account-execution entry point
    ///      the prototype's SimpleAccount uses. No other execute-style method is accepted.
    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));

    address public immutable entryPoint;
    address public immutable registry; // AnnouncementRegistry — only caller allowed for mirrorEligible
    address public immutable creditPool; // the only permitted execution target

    // Mirrored state (own storage only — ERC-7562 compliant)
    mapping(address => bool) private _eligible;
    mapping(address => bool) private _used;

    // selector of CreditPool.deposit(uint256)
    bytes4 private immutable _depositSelector;

    error NotEntryPoint();
    error NotRegistry();
    error NotEligible(address sender);
    error AlreadyUsed(address sender);
    error WrongCallTarget();
    error MaxCostExceeded(uint256 requested, uint256 cap);
    error GasPriceCapExceeded(uint256 requested, uint256 cap);

    event EligibilityMirrored(address indexed stealthAddress);
    event BootstrapSponsored(address indexed stealthAddress);

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    /// @param _entryPoint  ERC-4337 v0.7 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
    /// @param _registry    AnnouncementRegistry address
    /// @param _creditPool  CreditPool address — the only permitted execution target
    /// @param depositSel   bytes4 selector of CreditPool.deposit(uint256)
    constructor(address _entryPoint, address _registry, address _creditPool, bytes4 depositSel) {
        entryPoint = _entryPoint;
        registry = _registry;
        creditPool = _creditPool;
        _depositSelector = depositSel;
    }

    /// @notice Called by AnnouncementRegistry.announceAndFund() to push eligibility
    ///         into this contract's own storage. This is the "mirror-and-stake" pattern
    ///         required by ERC-7562.
    function mirrorEligible(address stealthAddress) external {
        if (msg.sender != registry) revert NotRegistry();
        _eligible[stealthAddress] = true;
        emit EligibilityMirrored(stealthAddress);
    }

    /// @notice ERC-4337 paymaster validation. Reads only own storage (_eligible, _used).
    ///         Sponsors iff: the operation is inside the sponsorship budget and gas-price
    ///         cap, the sender is eligible and has not used its bootstrap grant, and
    ///         callData is exactly
    ///           execute(creditPool, 0, abi.encodeCall(CreditPool.deposit, (commitment)))
    ///         on the sender account. The account-execution wrapper is required because the
    ///         EntryPoint runs callData on userOp.sender, not on the pool.
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, /* userOpHash */
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // ── 0. Enforce the bootstrap sponsorship budget (c_boot * p_max) ────
        // maxCost is the EntryPoint's requiredPrefund: the largest amount this
        // paymaster's deposit can be debited for this operation.
        if (maxCost > MAX_BOOTSTRAP_SPONSORSHIP_COST) {
            revert MaxCostExceeded(maxCost, MAX_BOOTSTRAP_SPONSORSHIP_COST);
        }

        uint256 maxFeePerGas = userOp.unpackMaxFeePerGas();
        if (maxFeePerGas > MAX_ACCEPTED_MAX_FEE_PER_GAS) {
            revert GasPriceCapExceeded(maxFeePerGas, MAX_ACCEPTED_MAX_FEE_PER_GAS);
        }

        address sender = userOp.sender;

        if (!EligibilityLogic.checkBootstrapEligible(
            _eligible[sender],
            _used[sender],
            userOp.callData,
            EXECUTE_SELECTOR,
            creditPool,
            _depositSelector
        )) {
            // Return SIG_VALIDATION_FAILED (1 in low bits) to signal rejection.
            return ("", 1);
        }

        // Mark used during validation to prevent double-sponsoring.
        // Note: if the subsequent deposit() reverts, the user loses their free-gas
        // attempt but retains the ability to call deposit() self-funded, since
        // CreditPool.deposit() enforces its own eligibility check independently.
        _used[sender] = true;

        emit BootstrapSponsored(sender);

        // Empty context — postOp will not be called.
        return ("", 0);
    }

    /// @dev Required by IPaymaster. Not called when context is empty.
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {}

    // ── View helpers ────────────────────────────────────────────────────────

    function isEligible(address addr) external view returns (bool) {
        return _eligible[addr];
    }

    function isUsed(address addr) external view returns (bool) {
        return _used[addr];
    }
}
