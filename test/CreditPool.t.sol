// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {CreditPool} from "../src/CreditPool.sol";

contract CreditPoolTest is TestBase {
    uint256 internal constant COMMITMENT = 12345678901234567890;

    function _makeEligible(address stealthAddr) internal {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealthAddr, bytes("pk"), bytes("")
        );
    }

    function test_deposit_happyPath() public {
        _makeEligible(stealth);

        uint256 rootBefore = creditPool.currentRoot();
        uint256 sizeBefore = creditPool.treeSize();

        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        // Tree grew by one leaf
        assertEq(creditPool.treeSize(), sizeBefore + 1);
        // Root changed
        assertTrue(creditPool.currentRoot() != rootBefore || sizeBefore == 0);
        // Marked as deposited
        assertTrue(creditPool.hasDeposited(stealth));
        // Root mirrored to CreditPaymaster
        assertEq(creditPM.merkleRoot(), creditPool.currentRoot());
    }

    function test_deposit_notEligible_reverts() public {
        vm.prank(stealth);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotEligible.selector, stealth));
        creditPool.deposit(COMMITMENT);
    }

    function test_deposit_alreadyDeposited_reverts() public {
        _makeEligible(stealth);

        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        vm.prank(stealth);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.AlreadyDeposited.selector, stealth));
        creditPool.deposit(COMMITMENT + 1);
    }

    function test_deposit_updatesRootInPaymaster() public {
        _makeEligible(stealth);

        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        assertEq(creditPM.merkleRoot(), creditPool.currentRoot());
        assertGt(creditPM.merkleRoot(), 0);
    }

    function test_mirrorEligible_notRegistry_reverts() public {
        vm.expectRevert(CreditPool.NotRegistry.selector);
        creditPool.mirrorEligible(stealth);
    }

    function test_multipleDepositors() public {
        address stealth2 = makeAddr("stealth2");
        vm.deal(stealth2, 1 ether);
        address sender2 = makeAddr("sender2");
        vm.deal(sender2, 10 ether);

        _makeEligible(stealth);

        vm.prank(sender2);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealth2, bytes("pk2"), bytes("")
        );

        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        vm.prank(stealth2);
        creditPool.deposit(COMMITMENT + 1);

        assertEq(creditPool.treeSize(), 2);
    }
}
