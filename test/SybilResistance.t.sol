// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {CreditPool} from "../src/CreditPool.sol";

/// @notice Verifies the sybil-resistance invariant:
///           nonRefundableFee > kappa * c_credit
///
///         Before the fee-split fix, V_MIN was fully forwarded to stealthAddress.
///         Because ERC-5564 doesn't cryptographically bind stealthAddress to a real
///         DKSAP derivation, an attacker who controls stealthAddress could recover
///         the forwarded ETH in the same block, making the real Sybil cost only c_ann
///         (gas), not V_MIN. The nonRefundableFee is burned to address(0) and cannot
///         be recovered regardless of who controls stealthAddress.
contract SybilResistanceTest is TestBase {
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 100 ether);
    }

    function test_subMinimum_rejected_byRegistry() public {
        // Sending only V_MIN (without fee) is below the required total
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                V_MIN,
                V_MIN + NONREFUNDABLE_FEE
            )
        );
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );
    }

    function test_zeroValue_rejected_byRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                0,
                V_MIN + NONREFUNDABLE_FEE
            )
        );
        registry.announceAndFund{value: 0}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );
    }

    function test_directDeposit_withoutAnnouncement_rejected() public {
        // Attacker tries to bypass registry and call deposit() directly.
        // CreditPool must reject because eligibility was never mirrored.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(CreditPool.NotEligible.selector, attacker)
        );
        creditPool.deposit(12345);
    }

    function test_exactMinimum_accepted() public {
        // Boundary: exactly vMin + nonRefundableFee should succeed and grant eligibility.
        vm.prank(attacker);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );
        assertTrue(registry.eligible(attacker));
        assertTrue(creditPool.isEligible(attacker));
    }

    function test_vMin_canBeUpdated_andNewThresholdEnforced() public {
        uint256 newVMin = 1 ether;

        vm.prank(deployer);
        registry.setVMin(newVMin);

        // Old V_MIN + FEE (0.01 + 0.01 = 0.02 ether) is now below required (1 + 0.01 ether)
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                V_MIN + NONREFUNDABLE_FEE,
                newVMin + NONREFUNDABLE_FEE
            )
        );
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );

        // New threshold accepted
        vm.prank(attacker);
        registry.announceAndFund{value: newVMin + NONREFUNDABLE_FEE}(
            SCHEME_ID, attacker, bytes("pk2"), bytes("")
        );
        assertTrue(registry.eligible(attacker));
    }

    /// @notice Simulates the complete self-dealing attack round trip.
    ///
    ///         Attack: attacker controls both the sender address and the stealthAddress.
    ///         They call announceAndFund(), then immediately withdraw the forwarded ETH
    ///         back to themselves.
    ///
    ///         The invariant must hold: attacker's net loss == nonRefundableFee,
    ///         regardless of how many times they recycle the forwarded ETH.
    ///         This is what makes V_MIN alone insufficient and nonRefundableFee necessary.
    function test_selfDealing_roundTrip_attackerLosesNonRefundableFee() public {
        address attackerStealth = makeAddr("attackerStealth"); // controlled by attacker
        // attackerStealth starts with 0 ETH (no deal() — fresh address)

        uint256 fee = registry.nonRefundableFee();
        uint256 total = V_MIN + fee;

        uint256 attackerBefore = attacker.balance;

        // Step 1: Attacker announces their own controlled stealth address
        vm.prank(attacker);
        registry.announceAndFund{value: total}(
            SCHEME_ID, attackerStealth, bytes("pk"), bytes("")
        );

        // V_MIN forwarded to attackerStealth; fee burned to address(0)
        assertEq(attackerStealth.balance, V_MIN, "forwarded amount mismatch");

        // Step 2: Attacker-controlled stealth address withdraws the forwarded ETH back
        vm.prank(attackerStealth);
        payable(attacker).transfer(attackerStealth.balance);

        assertEq(attackerStealth.balance, 0, "stealth should be empty after withdrawal");

        uint256 attackerAfter = attacker.balance;

        // Net loss = nonRefundableFee only — the forwarded V_MIN was fully recycled
        assertEq(
            attackerBefore - attackerAfter,
            fee,
            "attacker net loss must equal nonRefundableFee (fee cannot be recovered)"
        );

        // Attacker did gain eligibility — but they paid the fee for it, which is the Sybil cost
        assertTrue(registry.eligible(attackerStealth));
        assertTrue(creditPool.isEligible(attackerStealth));
    }
}
