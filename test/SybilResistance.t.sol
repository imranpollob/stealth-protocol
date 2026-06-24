// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {CreditPool} from "../src/CreditPool.sol";

/// @notice Verifies the sybil-resistance invariant:
///           V_MIN > c_ann + kappa * c_credit
///
///         The invariant holds because:
///         1. Registry rejects announceAndFund() with msg.value < vMin.
///         2. CreditPool.deposit() rejects callers not in its own eligibility map,
///            so an attacker cannot bypass BootstrapPaymaster by calling deposit()
///            directly — they would still need to have passed through announceAndFund().
contract SybilResistanceTest is TestBase {
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 100 ether);
    }

    function test_subVMin_rejected_byRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                V_MIN - 1,
                V_MIN
            )
        );
        registry.announceAndFund{value: V_MIN - 1}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );
    }

    function test_zeroValue_rejected_byRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                0,
                V_MIN
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

    function test_exactVMin_accepted() public {
        // Boundary: exactly vMin should succeed and grant eligibility.
        vm.prank(attacker);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );
        assertTrue(registry.eligible(attacker));
        assertTrue(creditPool.isEligible(attacker));
    }

    function test_vMin_canBeUpdated_andNewThresholdEnforced() public {
        uint256 newVMin = 1 ether;

        vm.prank(deployer);
        registry.setVMin(newVMin);

        // Old V_MIN (0.01 ether) now rejected
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AnnouncementRegistry.BelowVMin.selector,
                V_MIN,
                newVMin
            )
        );
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, attacker, bytes("pk"), bytes("")
        );

        // New threshold accepted
        vm.prank(attacker);
        registry.announceAndFund{value: newVMin}(
            SCHEME_ID, attacker, bytes("pk2"), bytes("")
        );
        assertTrue(registry.eligible(attacker));
    }
}
