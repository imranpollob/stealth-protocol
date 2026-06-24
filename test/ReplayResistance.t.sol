// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Verifies that a spent nullifier cannot be replayed.
///         The nullifier is scoped to a specific userOpHash (via scope field),
///         so even if the attacker tries a different userOp, they need a new proof
///         (different externalNullifier → different nullifierHash from the circuit).
///         This test shows the on-chain nullifier set correctly blocks double-spend.
contract ReplayResistanceTest is TestBase {
    uint256 internal constant COMMITMENT = 777888999000;
    uint256 internal constant NULLIFIER  = 111222333444;

    function _deposit() internal returns (uint256) {
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("pk"), bytes("")
        );
        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);
        return creditPool.currentRoot();
    }

    function test_nullifierRejectedOnSecondUse() public {
        uint256 poolRoot = _deposit();
        bytes32 uopHash = bytes32(uint256(0xCAFEBABE));

        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        bytes memory proofEncoded = abi.encode(proof);
        PackedUserOperation memory userOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded
        );

        // First use — succeeds
        vm.prank(ENTRY_POINT);
        (, uint256 v1) = creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
        assertEq(v1, 0);

        // Second use with same nullifier — must fail
        bytes32 uopHash2 = bytes32(uint256(0xDEADF00D));
        ISemaphore.SemaphoreProof memory proof2 = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash2);
        // Overwrite scope/message to match the new userOpHash
        proof2.scope = uint256(uopHash2);
        proof2.message = uint256(uopHash2);
        bytes memory proofEncoded2 = abi.encode(proof2);
        PackedUserOperation memory userOp2 = buildCreditUserOp(spender, bytes32(0), proof2, uopHash2);
        userOp2.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded2
        );

        vm.prank(ENTRY_POINT);
        vm.expectRevert(
            abi.encodeWithSelector(CreditPaymaster.NullifierSpent.selector, NULLIFIER)
        );
        creditPM.validatePaymasterUserOp(userOp2, uopHash2, 0);
    }

    function test_differentNullifiers_bothAccepted() public {
        // Two credits deposited by two different stealth addresses can both spend once.
        address stealth2 = makeAddr("stealth2");
        vm.deal(stealth2, 1 ether);
        address sender2 = makeAddr("sender2");
        vm.deal(sender2, 10 ether);

        // Deposit 1
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("pk1"), bytes("")
        );
        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        // Deposit 2
        vm.prank(sender2);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth2, bytes("pk2"), bytes("")
        );
        vm.prank(stealth2);
        creditPool.deposit(COMMITMENT + 1);

        uint256 poolRoot = creditPool.currentRoot();

        uint256 nullifier2 = NULLIFIER + 1;
        bytes32 uopHash1 = bytes32(uint256(0x1111));
        bytes32 uopHash2 = bytes32(uint256(0x2222));

        // Both spend with different nullifiers
        ISemaphore.SemaphoreProof memory proof1 = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash1);
        ISemaphore.SemaphoreProof memory proof2 = buildProof(COMMITMENT + 1, nullifier2, poolRoot, uopHash2);

        bytes memory enc1 = abi.encode(proof1);
        PackedUserOperation memory op1 = buildCreditUserOp(spender, bytes32(0), proof1, uopHash1);
        op1.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), enc1
        );

        bytes memory enc2 = abi.encode(proof2);
        PackedUserOperation memory op2 = buildCreditUserOp(spender, bytes32(0), proof2, uopHash2);
        op2.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), enc2
        );

        vm.prank(ENTRY_POINT);
        (, uint256 v1) = creditPM.validatePaymasterUserOp(op1, uopHash1, 0);
        assertEq(v1, 0);

        vm.prank(ENTRY_POINT);
        (, uint256 v2) = creditPM.validatePaymasterUserOp(op2, uopHash2, 0);
        assertEq(v2, 0);

        assertTrue(creditPM.isNullifierSpent(NULLIFIER));
        assertTrue(creditPM.isNullifierSpent(nullifier2));
    }
}
