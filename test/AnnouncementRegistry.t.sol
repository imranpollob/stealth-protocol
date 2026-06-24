// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";

contract AnnouncementRegistryTest is TestBase {
    function test_announceAndFund_happyPath() public {
        uint256 stealthBalanceBefore = stealth.balance;
        bool eligibleBefore = registry.eligible(stealth);
        assertFalse(eligibleBefore);

        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );

        // Only V_MIN is forwarded (fee was burned); stealth balance rises by exactly V_MIN
        assertEq(stealth.balance, stealthBalanceBefore + V_MIN);

        // Eligibility set in registry's own storage
        assertTrue(registry.eligible(stealth));

        // Eligibility mirrored to BootstrapPaymaster
        assertTrue(bootstrapPM.isEligible(stealth));

        // Eligibility mirrored to CreditPool
        assertTrue(creditPool.isEligible(stealth));
    }

    function test_announceAndFund_belowVMin_reverts() public {
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                V_MIN - 1,
                V_MIN + NONREFUNDABLE_FEE
            )
        );
        registry.announceAndFund{value: V_MIN - 1}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
    }

    function test_announceAndFund_exactMinimum_accepted() public {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
        assertTrue(registry.eligible(stealth));
    }

    function test_announceAndFund_aboveMinimum_accepted() public {
        uint256 extra = 0.5 ether;
        uint256 total = V_MIN + NONREFUNDABLE_FEE + extra;

        vm.prank(sender);
        registry.announceAndFund{value: total}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
        assertTrue(registry.eligible(stealth));
        // Forwarded = total - fee = V_MIN + extra
        assertGe(stealth.balance, V_MIN + extra);
    }

    function test_setVMin_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(AnnouncementRegistry.Unauthorized.selector);
        registry.setVMin(1 ether);
    }

    function test_setVMin_byOwner() public {
        vm.prank(deployer);
        registry.setVMin(1 ether);
        assertEq(registry.vMin(), 1 ether);
    }

    function test_setNonRefundableFee_byOwner() public {
        vm.prank(deployer);
        registry.setNonRefundableFee(0.05 ether);
        assertEq(registry.nonRefundableFee(), 0.05 ether);
    }

    function test_eligibility_notSet_forDirectAnnouncer() public {
        // Direct announcer calls (bypassing registry) produce no eligibility
        vm.prank(sender);
        announcer.announce(SCHEME_ID, stealth, bytes("pubkey"), bytes(""));
        assertFalse(registry.eligible(stealth));
    }
}

// Bring AnnouncementRegistry into scope for error selectors
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
