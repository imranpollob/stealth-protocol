// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {FunctionalCorrectnessFixture} from "./FunctionalCorrectnessFixture.sol";

/// @title BootstrapSponsorshipBound
/// @notice Economic bound on the Bootstrap phase, exercised through the real ERC-4337
///         EntryPoint (account-abstraction v0.9) so that `maxCost` carries its actual
///         meaning — the EntryPoint's requiredPrefund, computed from all five gas terms —
///         rather than a value chosen by the test.
///
///         Together with `CreditPaymaster.MAX_SPONSORSHIP_COST`, this bounds the total
///         sponsored exposure of one PrivGas credit:
///           c_credit * p_max = 0.005 ETH (bootstrap) + 0.005 ETH (spend) = 0.01 ETH
///         which is the quantity the Sybil-resistance invariant F > kappa * c_credit * p_max
///         is stated against.
///
///         Scope note: these three cases cover the sponsorship bound only. Bootstrap
///         eligibility and the deposit-callData restriction are unchanged and are already
///         covered by BootstrapPaymaster.t.sol.
contract BootstrapSponsorshipBoundTest is Test, FunctionalCorrectnessFixture {
    uint256 internal constant COMMITMENT = 42424242;

    // Gas shape of a bootstrap operation. At 1 gwei the prefund is
    // (100 000 + 200 000 + 100 000 + 0 + 21 000) * 1 gwei = 4.21e14 wei = 0.000421 ETH,
    // comfortably inside the 0.005 ETH budget.
    uint128 internal constant BOOT_VERIFICATION_GAS = 100_000;
    uint128 internal constant BOOT_CALL_GAS = 200_000;
    uint128 internal constant BOOT_PM_VERIFICATION_GAS = 100_000;
    uint256 internal constant BOOT_PRE_VERIFICATION_GAS = 21_000;

    /// Inflates requiredPrefund past 0.005 ETH while leaving maxFeePerGas at 1 gwei,
    /// so the budget check is the only thing that can reject the operation.
    uint128 internal constant OVER_BUDGET_PM_GAS = 5_000_000;

    address payable internal beneficiary;

    function setUp() public {
        _deployAll();

        beneficiary = payable(address(uint160(uint256(keccak256("privgas.boot.beneficiary")))));

        // accountA becomes an eligible stealth address via the fee-paying announcement path.
        vm.deal(FUNDER, 100 ether);
        vm.prank(FUNDER);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, address(accountA), bytes("ephemeralPubKey"), bytes("")
        );
        assertTrue(bootstrapPM.isEligible(address(accountA)), "sender must be bootstrap-eligible");

        vm.deal(address(this), 100 ether);
        entryPoint.depositTo{value: 10 ether}(address(bootstrapPM));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Bootstrap sponsorship within budget -> ACCEPTED
    // ─────────────────────────────────────────────────────────────────────────
    //  Asserts the *sponsorship* decision: the paymaster accepts the operation, commits
    //  its single-use grant for this address, and is charged by the EntryPoint. Measured
    //  prefund is 4.21e14 wei.
    //
    //  Deliberately not asserted: that the credit lands in CreditPool. BootstrapPaymaster
    //  requires callData to be exactly `deposit(uint256)`, but ERC-4337 executes callData
    //  *on userOp.sender*, so the EntryPoint calls `SimpleAccount.deposit(...)`, which does
    //  not exist, and UserOperationEvent reports success: false. Reaching CreditPool would
    //  need callData `execute(creditPool, 0, deposit(commitment))`, which the paymaster's
    //  36-byte selector check rejects. That is a pre-existing property of the callData
    //  restriction, out of scope here, and it does not affect the economic bound this
    //  file tests — the paymaster is charged either way, which is precisely why the
    //  prefund cap is the thing that has to be enforced.
    function test_bootstrapSponsorship_withinBudget_accepted() public {
        PackedUserOperation memory op = _sign(_bootstrapOp(BOOT_PM_VERIFICATION_GAS, 1 gwei));

        uint256 expectedMaxCost = _expectedMaxCost(BOOT_PM_VERIFICATION_GAS, 1 gwei);
        assertLe(
            expectedMaxCost,
            bootstrapPM.MAX_BOOTSTRAP_SPONSORSHIP_COST(),
            "reference operation must sit inside the budget"
        );

        uint256 depositBefore = entryPoint.balanceOf(address(bootstrapPM));

        _handleOps(op);

        // The paymaster accepted and committed its single-use sponsorship for this address.
        assertTrue(bootstrapPM.isUsed(address(accountA)), "bootstrap sponsorship must be consumed");
        assertLt(entryPoint.balanceOf(address(bootstrapPM)), depositBefore, "paymaster must have been charged");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. maxCost above the bootstrap budget -> REJECTED
    // ─────────────────────────────────────────────────────────────────────────
    function test_bootstrapSponsorship_maxCostExceedsBudget_rejected() public {
        PackedUserOperation memory op = _sign(_bootstrapOp(OVER_BUDGET_PM_GAS, 1 gwei));

        uint256 expectedMaxCost = _expectedMaxCost(OVER_BUDGET_PM_GAS, 1 gwei);
        assertGt(
            expectedMaxCost, bootstrapPM.MAX_BOOTSTRAP_SPONSORSHIP_COST(), "operation must exceed the budget"
        );

        _expectPaymasterRevert(
            abi.encodeWithSelector(
                BootstrapPaymaster.MaxCostExceeded.selector,
                expectedMaxCost,
                bootstrapPM.MAX_BOOTSTRAP_SPONSORSHIP_COST()
            )
        );
        _handleOps(op);

        assertFalse(bootstrapPM.isUsed(address(accountA)), "a rejected operation must not consume the sponsorship");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. maxFeePerGas above p_max -> REJECTED
    // ─────────────────────────────────────────────────────────────────────────
    //  At 11 gwei the prefund is 421 000 * 11 gwei = 4.631e15 wei, still inside the
    //  0.005 ETH budget — so the gas-price cap is the only thing that can reject it.
    function test_bootstrapSponsorship_gasPriceExceedsCap_rejected() public {
        uint128 overCapFee = 11 gwei;
        PackedUserOperation memory op = _sign(_bootstrapOp(BOOT_PM_VERIFICATION_GAS, overCapFee));

        assertLe(
            _expectedMaxCost(BOOT_PM_VERIFICATION_GAS, overCapFee),
            bootstrapPM.MAX_BOOTSTRAP_SPONSORSHIP_COST(),
            "budget check must not be what rejects this operation"
        );

        _expectPaymasterRevert(
            abi.encodeWithSelector(
                BootstrapPaymaster.GasPriceCapExceeded.selector,
                uint256(overCapFee),
                bootstrapPM.MAX_ACCEPTED_MAX_FEE_PER_GAS()
            )
        );
        _handleOps(op);

        assertFalse(bootstrapPM.isUsed(address(accountA)), "a rejected operation must not consume the sponsorship");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Full Bootstrap operation, end to end through the EntryPoint
    // ─────────────────────────────────────────────────────────────────────────
    //  eligible account -> BootstrapPaymaster sponsorship -> SimpleAccount.execute(...)
    //  -> CreditPool.deposit(commitment) -> credit in the tree, root mirrored.
    function test_bootstrapDeposit_endToEnd_succeeds() public {
        assertEq(creditPool.treeSize(), 0, "pool must start empty");
        assertEq(creditPM.merkleRoot(), 0, "mirrored root must start empty");

        PackedUserOperation memory op = _sign(_bootstrapOp(BOOT_PM_VERIFICATION_GAS, 1 gwei));
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        uint256 depositBefore = entryPoint.balanceOf(address(bootstrapPM));

        vm.recordLogs();
        _handleOps(op);

        // 1. the UserOperation itself succeeded
        assertTrue(_userOpSucceeded(userOpHash), "UserOperationEvent must report success");

        // 2. the paymaster consumed its single-use grant for this account
        assertTrue(bootstrapPM.isUsed(address(accountA)), "bootstrap sponsorship must be consumed");

        // 3. the commitment actually reached CreditPool, credited to the account
        assertEq(creditPool.treeSize(), 1, "commitment must be inserted");
        assertTrue(creditPool.hasDeposited(address(accountA)), "deposit must be recorded for the sender");

        // 4. the root advanced, and for a single-leaf LeanIMT it equals the commitment —
        //    so this is the exact value the operation carried, not just "some" insertion
        uint256 newRoot = creditPool.currentRoot();
        assertTrue(newRoot != 0, "root must have advanced");
        assertEq(newRoot, COMMITMENT, "single-leaf root must equal the deposited commitment");

        // 5. the new root was mirrored into CreditPaymaster
        assertEq(creditPM.merkleRoot(), newRoot, "root must be mirrored to CreditPaymaster");

        // 6. the paymaster's EntryPoint deposit paid for it
        assertLt(entryPoint.balanceOf(address(bootstrapPM)), depositBefore, "paymaster must have been charged");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Call-shape rejections
    // ─────────────────────────────────────────────────────────────────────────
    //  A rejected call shape returns SIG_VALIDATION_FAILED, which the EntryPoint surfaces
    //  as FailedOp(0, "AA34 signature error").
    function test_bootstrapDeposit_executeToOtherTarget_rejected() public {
        bytes memory callData = abi.encodeCall(
            BaseAccount.execute, (address(target), 0, abi.encodeCall(CreditPool.deposit, (COMMITMENT)))
        );
        // Sign before arming expectRevert — _sign calls getUserOpHash, which would consume it.
        PackedUserOperation memory op = _sign(_bootstrapOpWithCallData(callData, BOOT_PM_VERIFICATION_GAS, 1 gwei));
        _expectSigValidationFailed();
        _handleOps(op);
    }

    function test_bootstrapDeposit_executeWithValue_rejected() public {
        bytes memory callData = abi.encodeCall(
            BaseAccount.execute, (address(creditPool), 1, abi.encodeCall(CreditPool.deposit, (COMMITMENT)))
        );
        PackedUserOperation memory op = _sign(_bootstrapOpWithCallData(callData, BOOT_PM_VERIFICATION_GAS, 1 gwei));
        _expectSigValidationFailed();
        _handleOps(op);
    }

    /// @dev `mirrorEligible(address)` encodes to the same 36-byte inner shape as
    ///      `deposit(uint256)`, so only the inner selector check can reject this.
    function test_bootstrapDeposit_executeWrongPoolFunction_rejected() public {
        bytes memory callData = abi.encodeCall(
            BaseAccount.execute,
            (address(creditPool), 0, abi.encodeCall(CreditPool.mirrorEligible, (address(accountA))))
        );
        PackedUserOperation memory op = _sign(_bootstrapOpWithCallData(callData, BOOT_PM_VERIFICATION_GAS, 1 gwei));
        _expectSigValidationFailed();
        _handleOps(op);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _expectSigValidationFailed() internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA34 signature error")
        );
    }

    /// @dev Reads the `success` flag out of the EntryPoint's UserOperationEvent.
    function _userOpSucceeded(bytes32 userOpHash) internal returns (bool) {
        bytes32 sig = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig && logs[i].topics[1] == userOpHash) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return success;
            }
        }
        revert("UserOperationEvent not emitted");
    }


    function _expectedMaxCost(uint128 pmVerificationGas, uint128 maxFeePerGas) internal pure returns (uint256) {
        return (
            uint256(BOOT_VERIFICATION_GAS) + BOOT_CALL_GAS + pmVerificationGas + 0 + BOOT_PRE_VERIFICATION_GAS
        ) * maxFeePerGas;
    }

    /// @dev callData is exactly `execute(creditPool, 0, deposit(commitment))` — the form
    ///      BootstrapPaymaster requires, and the form the EntryPoint can actually execute
    ///      (it runs callData on userOp.sender, which is the SimpleAccount).
    function _depositCallData() internal view returns (bytes memory) {
        return abi.encodeCall(
            BaseAccount.execute,
            (address(creditPool), 0, abi.encodeCall(CreditPool.deposit, (COMMITMENT)))
        );
    }

    function _bootstrapOp(uint128 pmVerificationGas, uint128 maxFeePerGas)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _bootstrapOpWithCallData(_depositCallData(), pmVerificationGas, maxFeePerGas);
    }

    function _bootstrapOpWithCallData(bytes memory callData, uint128 pmVerificationGas, uint128 maxFeePerGas)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(accountA);
        op.nonce = 0;
        op.initCode = "";
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(BOOT_VERIFICATION_GAS, BOOT_CALL_GAS));
        op.preVerificationGas = BOOT_PRE_VERIFICATION_GAS;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), maxFeePerGas));
        op.paymasterAndData = abi.encodePacked(address(bootstrapPM), pmVerificationGas, uint128(0));
        op.signature = "";
    }

    function _sign(PackedUserOperation memory op) internal view returns (PackedUserOperation memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_A_KEY, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function _handleOps(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _expectPaymasterRevert(bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, uint256(0), "AA33 reverted", inner)
        );
    }
}
