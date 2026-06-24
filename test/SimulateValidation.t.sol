// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {MockAnnouncer} from "./mock/MockAnnouncer.sol";
import {MockSemaphoreVerifier} from "./mock/MockSemaphoreVerifier.sol";
import {MockAccount} from "./mock/MockAccount.sol";

/// @notice Integration test that runs EntryPoint.simulateValidation() against both
///         paymasters to confirm they do not revert under the real ERC-4337 validation
///         flow (not just direct validatePaymasterUserOp calls via vm.prank).
///
///         What simulateValidation confirms:
///           1. Both paymasters pass the full EntryPoint validation dispatch without reverting.
///           2. Both return SIG_VALIDATION_SUCCESS (validationData == 0).
///           3. Gas figures for the validation phase are available in the return struct.
///           4. Paymaster deposits and stake are set up correctly.
///
///         What simulateValidation does NOT automate (honest disclosure):
///           - Forbidden opcode checking (TIMESTAMP, NUMBER, COINBASE, etc.)  — requires
///             a bundler client that traces opcodes. ERC-7562 compliance for opcodes is
///             verified by code review (no banned opcodes appear in any validation path).
///
///         CreditPaymaster circular-dependency fix (v1.1):
///           The previous design read proof bytes from userOp.paymasterAndData[52:], which
///           included the proof in paymasterDataKeccak → userOpHash. Since proof.message must
///           equal userOpHash, there was a circular dependency with no pre-computable solution.
///           Fix: CreditPaymaster now uses the ERC-4337 PAYMASTER_SIG_MAGIC convention —
///             paymasterAndData = [address][verGas][postGas][proofBytes][uint16(len)][magic]
///           paymasterDataKeccak sees the magic and excludes the proof bytes from userOpHash,
///           making it stable before proof generation. Both paymasters now pass simulateValidation.
contract SimulateValidationTest is Test {
    // keccak("PaymasterSignature")[:8]
    bytes8 internal constant PAYMASTER_SIG_MAGIC = bytes8(0x22e325a297439656);
    uint256 internal constant CREDIT_NULLIFIER_SCOPE = uint256(keccak256("stealth-protocol.credit.v1"));

    EntryPointSimulations internal eps;
    MockAccount internal stealthAccount;
    MockAccount internal spenderAccount;

    AnnouncementRegistry internal registry;
    BootstrapPaymaster internal bootstrapPM;
    CreditPool internal creditPool;
    CreditPaymaster internal creditPM;
    MockAnnouncer internal announcer;
    MockSemaphoreVerifier internal verifier;

    address internal deployer = makeAddr("deployer");

    uint256 constant V_MIN             = 0.01 ether;
    uint256 constant NONREFUNDABLE_FEE = 0.01 ether;
    // Must be < BN254 scalar field r; LeanIMT rejects leaves that exceed it
    uint256 constant CREDIT_COMMITMENT = 42424242;

    function setUp() public {
        // Deploy EntryPointSimulations at a local address.
        // All protocol contracts are wired to address(eps) so that the msg.sender
        // == entryPoint check inside each paymaster passes during simulateValidation.
        eps = new EntryPointSimulations();

        vm.deal(deployer, 100 ether);
        vm.startPrank(deployer);

        announcer = new MockAnnouncer();
        verifier  = new MockSemaphoreVerifier(true);

        uint64 nonce = vm.getNonce(deployer);
        address creditPMAddr    = vm.computeCreateAddress(deployer, nonce);
        address creditPoolAddr  = vm.computeCreateAddress(deployer, nonce + 1);
        address bootstrapPMAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address registryAddr    = vm.computeCreateAddress(deployer, nonce + 3);

        creditPM    = new CreditPaymaster(address(eps), creditPoolAddr, address(verifier));
        creditPool  = new CreditPool(creditPMAddr, registryAddr);
        bootstrapPM = new BootstrapPaymaster(address(eps), registryAddr, CreditPool.deposit.selector);
        registry    = new AnnouncementRegistry(
            address(announcer), bootstrapPMAddr, creditPoolAddr, V_MIN, NONREFUNDABLE_FEE
        );
        vm.stopPrank();

        // Deploy mock accounts to act as UserOp senders.
        stealthAccount = new MockAccount(address(eps));
        spenderAccount = new MockAccount(address(eps));
        vm.deal(address(stealthAccount), 1 ether);
        vm.deal(address(spenderAccount), 1 ether);

        // Fund accounts at the local EntryPoint (covers any missingAccountFunds).
        vm.deal(address(this), 20 ether);
        eps.depositTo{value: 1 ether}(address(stealthAccount));
        eps.depositTo{value: 1 ether}(address(spenderAccount));

        // Fund paymaster deposits — simulateValidation will deduct requiredPreFund
        // from these and revert with AA31 if the deposit is insufficient.
        eps.depositTo{value: 5 ether}(address(bootstrapPM));
        eps.depositTo{value: 5 ether}(address(creditPM));

        // Stake both paymasters.  Staking is required by the ERC-7562 bundler rule
        // (paymasters that read own storage must be staked), and is verified via
        // the returned paymasterInfo.stake in the assertions below.
        vm.deal(address(bootstrapPM), 1 ether);
        vm.prank(address(bootstrapPM));
        eps.addStake{value: 0.5 ether}(1);

        vm.deal(address(creditPM), 1 ether);
        vm.prank(address(creditPM));
        eps.addStake{value: 0.5 ether}(1);

        // Make stealthAccount eligible via announceAndFund (bootstrapPM + creditPool mirror).
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            1, address(stealthAccount), bytes("pk"), bytes("")
        );

        // Complete the bootstrap: deposit commitment so creditPM has a nonzero Merkle root.
        // We call creditPool directly (stealthAccount is eligible; this simulates what the
        // BootstrapPaymaster-sponsored UserOp execution would do).
        vm.prank(address(stealthAccount));
        creditPool.deposit(CREDIT_COMMITMENT);

        // ── CRITICAL: initialize __domainSeparatorV4 ─────────────────────────
        // EntryPointSimulations stores the domain separator in a regular storage slot
        // (__domainSeparatorV4) rather than an immutable.  It is set only when
        // _simulationOnlyValidations() runs (i.e., inside simulateValidation).
        // Until then getDomainSeparatorV4() returns 0, making getUserOpHash() compute
        // a wrong hash that doesn't match what simulateValidation will pass to paymasters.
        //
        // Fix: run one successful simulateValidation here so the domain separator is
        // initialized before the test calls getUserOpHash().  We use a bootstrap op for
        // stealthAccount (eligible, bootstrapPM._used not yet set → validation passes).
        // Side-effect: bootstrapPM._used[stealthAccount] = true after this call.
        {
            PackedUserOperation memory initOp;
            initOp.sender             = address(stealthAccount);
            initOp.nonce              = 0;
            initOp.callData           = abi.encodeCall(CreditPool.deposit, (CREDIT_COMMITMENT));
            initOp.accountGasLimits   = bytes32(abi.encodePacked(uint128(100_000), uint128(200_000)));
            initOp.preVerificationGas = 21_000;
            initOp.gasFees            = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
            initOp.paymasterAndData   = abi.encodePacked(address(bootstrapPM), uint128(100_000), uint128(0));
            eps.simulateValidation(initOp);
        }
        // __domainSeparatorV4 is now set. Subsequent getUserOpHash() calls return the
        // correct value that simulateValidation will also use internally.
    }

    /// @notice Confirm BootstrapPaymaster passes simulateValidation.
    ///         Scenario: the UserOp calls CreditPool.deposit() on behalf of the
    ///         eligible stealthAccount.  The paymaster reads only its own storage
    ///         (_eligible, _used) — the mirror-and-stake pattern.
    ///
    ///         Note: stealthAccount's creditPool._used is already set from setUp().
    ///         BootstrapPaymaster._used is distinct — it's set during validatePaymasterUserOp.
    ///         A fresh stealthAccount2 is used here to avoid the AlreadyUsed revert in creditPool.
    function test_bootstrapPaymaster_simulateValidation_passes() public {
        // Use a second eligible stealth account so creditPool.deposit() doesn't hit AlreadyUsed
        MockAccount stealthAccount2 = new MockAccount(address(eps));
        vm.deal(address(stealthAccount2), 1 ether);
        eps.depositTo{value: 1 ether}(address(stealthAccount2));
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            1, address(stealthAccount2), bytes("pk2"), bytes("")
        );

        PackedUserOperation memory userOp;
        userOp.sender             = address(stealthAccount2);
        userOp.nonce              = 0;
        userOp.callData           = abi.encodeCall(CreditPool.deposit, (uint256(0xdeadbeef)));
        userOp.accountGasLimits   = bytes32(abi.encodePacked(uint128(100_000), uint128(200_000)));
        userOp.preVerificationGas = 21_000;
        userOp.gasFees            = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        userOp.paymasterAndData   = abi.encodePacked(
            address(bootstrapPM), uint128(100_000), uint128(0)
        );

        IEntryPointSimulations.ValidationResult memory result = eps.simulateValidation(userOp);

        assertEq(
            result.returnInfo.paymasterValidationData, 0,
            "BootstrapPaymaster must return SIG_VALIDATION_SUCCESS"
        );
        assertEq(
            result.returnInfo.accountValidationData, 0,
            "MockAccount must return SIG_VALIDATION_SUCCESS"
        );
        assertGt(result.paymasterInfo.stake, 0, "paymaster must be staked");

        console.log("BootstrapPaymaster simulateValidation: PASS");
        console.log("  preOpGas:                 ", result.returnInfo.preOpGas);
        console.log("  paymasterValidationData:  ", result.returnInfo.paymasterValidationData);
        console.log("  paymasterInfo.stake (wei):", result.paymasterInfo.stake);
        console.log("  paymasterInfo.unstakeDelaySec:", result.paymasterInfo.unstakeDelaySec);
    }

    /// @notice Confirm CreditPaymaster passes simulateValidation.
    ///
    ///         Fix applied: CreditPaymaster now reads proof via getPaymasterSignature()
    ///         (PAYMASTER_SIG_MAGIC convention) so proof bytes are excluded from
    ///         paymasterDataKeccak and userOpHash is stable before proof generation.
    ///
    ///         Two-phase encoding:
    ///           Phase 1 — build UserOp with placeholder proof, get stable hash.
    ///           Phase 2 — set proof.message = userOpHash and fixed credit scope, re-encode, run.
    function test_creditPaymaster_simulateValidation_passes() public {
        uint256 poolRoot = creditPM.merkleRoot();
        assertGt(poolRoot, 0, "creditPM root must be nonzero (set during setUp bootstrap)");

        uint256 nullifier = uint256(keccak256("sim_nullifier"));

        // ── Phase 1: build UserOp with placeholder proof to obtain the stable hash ──
        // With PAYMASTER_SIG_MAGIC, proof bytes are excluded from paymasterDataKeccak,
        // so userOpHash does not depend on proof.message — no circular dependency.
        bytes memory placeholderProofEncoded = abi.encode(ISemaphore.SemaphoreProof({
            merkleTreeDepth: 1,
            merkleTreeRoot: poolRoot,
            nullifier: nullifier,
            message: 0,   // placeholder
            scope: 0,     // placeholder
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        }));

        PackedUserOperation memory spendOp;
        spendOp.sender             = address(spenderAccount);
        spendOp.nonce              = 0;
        spendOp.callData           = abi.encodeWithSignature("doSomething()");
        spendOp.accountGasLimits   = bytes32(abi.encodePacked(uint128(50_000), uint128(100_000)));
        spendOp.preVerificationGas = 21_000;
        spendOp.gasFees            = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        spendOp.paymasterAndData   = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0),
            placeholderProofEncoded,
            uint16(placeholderProofEncoded.length),
            PAYMASTER_SIG_MAGIC
        );

        // ── Phase 2: get stable hash, update proof, re-encode ─────────────────────
        // eps.getUserOpHash is stable regardless of proof bytes (magic excludes them).
        bytes32 userOpHash = eps.getUserOpHash(spendOp);

        bytes memory proofEncoded = abi.encode(ISemaphore.SemaphoreProof({
            merkleTreeDepth: 1,
            merkleTreeRoot: poolRoot,
            nullifier: nullifier,
            message: uint256(userOpHash),
            scope: CREDIT_NULLIFIER_SCOPE,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        }));

        spendOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0),
            proofEncoded, uint16(proofEncoded.length), PAYMASTER_SIG_MAGIC
        );

        // Verify the hash is indeed unchanged after updating the proof bytes
        assertEq(eps.getUserOpHash(spendOp), userOpHash, "userOpHash must be stable regardless of proof bytes");

        // ── Phase 3: simulateValidation ───────────────────────────────────────────
        IEntryPointSimulations.ValidationResult memory result = eps.simulateValidation(spendOp);

        assertEq(
            result.returnInfo.paymasterValidationData, 0,
            "CreditPaymaster must return SIG_VALIDATION_SUCCESS"
        );
        assertEq(
            result.returnInfo.accountValidationData, 0,
            "MockAccount must return SIG_VALIDATION_SUCCESS"
        );
        assertGt(result.paymasterInfo.stake, 0, "paymaster must be staked");

        console.log("CreditPaymaster simulateValidation: PASS");
        console.log("  preOpGas:                 ", result.returnInfo.preOpGas);
        console.log("  paymasterValidationData:  ", result.returnInfo.paymasterValidationData);
        console.log("  paymasterInfo.stake (wei):", result.paymasterInfo.stake);
        console.log("  paymasterInfo.unstakeDelaySec:", result.paymasterInfo.unstakeDelaySec);
    }
}
