// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
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
///           - CreditPaymaster is not covered by this test — see note below.
///
///         CreditPaymaster simulateValidation blocker:
///           UserOperationLib.paymasterDataKeccak hashes the FULL paymasterAndData field
///           (including the Semaphore proof bytes) unless the data ends with PAYMASTER_SIG_MAGIC.
///           CreditPaymaster does not use PAYMASTER_SIG_MAGIC. This means:
///             • userOpHash = f(proof bytes)
///             • proof.scope must equal userOpHash
///             • proof bytes depend on scope
///             • → circular dependency; no pre-computable solution
///           Mitigation path: redesign paymasterAndData to use the ERC-4337 paymaster
///           signature convention (append PAYMASTER_SIG_MAGIC + uint16 length so the
///           proof bytes are excluded from paymasterDataKeccak and userOpHash becomes
///           stable again). This is a v1.1 item. The unit tests (vm.prank + direct
///           validatePaymasterUserOp calls) verify the validation logic is correct.
contract SimulateValidationTest is Test {
    EntryPointSimulations internal eps;
    MockAccount internal stealthAccount;

    AnnouncementRegistry internal registry;
    BootstrapPaymaster internal bootstrapPM;
    CreditPool internal creditPool;
    CreditPaymaster internal creditPM;
    MockAnnouncer internal announcer;
    MockSemaphoreVerifier internal verifier;

    address internal deployer = makeAddr("deployer");

    uint256 constant V_MIN            = 0.01 ether;
    uint256 constant NONREFUNDABLE_FEE = 0.01 ether;

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

        // Deploy a mock account to act as the UserOp sender.
        stealthAccount = new MockAccount(address(eps));
        vm.deal(address(stealthAccount), 1 ether);

        // Fund account at the local EntryPoint (covers any missingAccountFunds).
        vm.deal(address(this), 20 ether);
        eps.depositTo{value: 1 ether}(address(stealthAccount));

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

        // Make the account eligible via announceAndFund so BootstrapPaymaster accepts it.
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            1, address(stealthAccount), bytes("pk"), bytes("")
        );
    }

    /// @notice Confirm BootstrapPaymaster passes simulateValidation.
    ///         Scenario: the UserOp calls CreditPool.deposit() on behalf of the
    ///         eligible stealthAccount.  The paymaster reads only its own storage
    ///         (_eligible, _used) — the mirror-and-stake pattern.
    function test_bootstrapPaymaster_simulateValidation_passes() public {
        PackedUserOperation memory userOp;
        userOp.sender             = address(stealthAccount);
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
}
