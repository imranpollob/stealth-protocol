// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";

contract AnnouncementRegistryTest is TestBase {
    function test_announceAndFund_happyPath() public {
        uint256 stealthBalanceBefore = stealth.balance;
        bool eligibleBefore = registry.eligible(stealth);
        assertFalse(eligibleBefore);

        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );

        // ETH forwarded to stealth address
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
                V_MIN
            )
        );
        registry.announceAndFund{value: V_MIN - 1}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
    }

    function test_announceAndFund_exactVMin_accepted() public {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
        assertTrue(registry.eligible(stealth));
    }

    function test_announceAndFund_aboveVMin_accepted() public {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN * 2}(
            SCHEME_ID, stealth, bytes("pubkey"), bytes("")
        );
        assertTrue(registry.eligible(stealth));
        // All ETH (not just vMin) forwarded
        assertGe(stealth.balance, V_MIN * 2);
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

    function test_eligibility_notSet_forDirectAnnouncer() public {
        // Direct announcer calls (bypassing registry) produce no eligibility
        vm.prank(sender);
        announcer.announce(SCHEME_ID, stealth, bytes("pubkey"), bytes(""));
        assertFalse(registry.eligible(stealth));
    }
}

// Bring AnnouncementRegistry into scope for error selectors
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
