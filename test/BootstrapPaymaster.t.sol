// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract BootstrapPaymasterTest is TestBase {
    function _fundAndEligible(address stealthAddr) internal {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealthAddr, bytes("pk"), bytes("")
        );
    }

    function test_validate_happyPath() public {
        _fundAndEligible(stealth);

        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 42);

        vm.prank(ENTRY_POINT);
        (bytes memory ctx, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(ctx.length, 0, "context should be empty");
        assertEq(validationData, 0, "validation should succeed");
    }

    function test_validate_marksUsed() public {
        _fundAndEligible(stealth);
        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);

        vm.prank(ENTRY_POINT);
        bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertTrue(bootstrapPM.isUsed(stealth));
    }

    function test_validate_notEligible_rejected() public {
        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);

        vm.prank(ENTRY_POINT);
        (, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, 1, "should return SIG_VALIDATION_FAILED");
    }

    function test_validate_alreadyUsed_rejected() public {
        _fundAndEligible(stealth);

        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);

        vm.prank(ENTRY_POINT);
        bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        // Second attempt — should be rejected
        vm.prank(ENTRY_POINT);
        (, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, 1);
    }

    function test_validate_wrongCallData_rejected() public {
        _fundAndEligible(stealth);

        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);
        // Override callData with something other than deposit(uint256)
        userOp.callData = abi.encodeWithSignature("transfer(address,uint256)", address(0), 100);

        vm.prank(ENTRY_POINT);
        (, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, 1);
    }

    function test_validate_wrongCallDataLength_rejected() public {
        _fundAndEligible(stealth);

        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);
        // Too short — 4-byte selector only, no argument
        userOp.callData = abi.encodeWithSelector(CreditPool.deposit.selector);

        vm.prank(ENTRY_POINT);
        (, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, 1);
    }

    function test_validate_notEntryPoint_reverts() public {
        PackedUserOperation memory userOp = buildDepositUserOp(stealth, 1);

        vm.expectRevert(BootstrapPaymaster.NotEntryPoint.selector);
        bootstrapPM.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_mirrorEligible_notRegistry_reverts() public {
        vm.expectRevert(BootstrapPaymaster.NotRegistry.selector);
        bootstrapPM.mirrorEligible(stealth);
    }
}

import {CreditPool} from "../src/CreditPool.sol";
