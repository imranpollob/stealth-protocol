// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract CreditPaymasterTest is TestBase {
    uint256 internal constant COMMITMENT = 99999888887777;
    uint256 internal constant NULLIFIER = 11111222223333;

    function _fullBootstrap() internal returns (uint256 poolRoot) {
        // Fund and announce
        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("pk"), bytes("")
        );
        // Deposit commitment into pool
        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);
        poolRoot = creditPool.currentRoot();
    }

    function _buildAndValidate(
        address _sender,
        ISemaphore.SemaphoreProof memory proof,
        bytes32 expectedUserOpHash
    ) internal returns (bytes memory ctx, uint256 validationData) {
        PackedUserOperation memory userOp = buildCreditUserOp(
            _sender,
            bytes32(abi.encodeWithSignature("doSomething()")),
            proof,
            expectedUserOpHash
        );
        // The hash computed by the EntryPoint; we need scope/message to match it
        // In tests we pre-compute the hash and set scope/message before building the op
        vm.prank(ENTRY_POINT);
        (ctx, validationData) = creditPM.validatePaymasterUserOp(userOp, expectedUserOpHash, 0);
    }

    function test_validate_happyPath() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));

        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        (, uint256 validationData) = _buildAndValidate(spender, proof, uopHash);
        assertEq(validationData, 0, "should succeed");
    }

    function test_validate_marksNullifierSpent() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        _buildAndValidate(spender, proof, uopHash);
        assertTrue(creditPM.isNullifierSpent(NULLIFIER));
    }

    function test_validate_wrongRoot_reverts() public {
        _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        uint256 badRoot = 9999999;

        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, badRoot, uopHash);

        PackedUserOperation memory userOp = buildCreditUserOp(
            spender, bytes32(0), proof, uopHash
        );

        // Cache before prank — creditPM.merkleRoot() is an external call that would consume prank.
        uint256 storedRoot = creditPM.merkleRoot();

        vm.prank(ENTRY_POINT);
        vm.expectRevert(
            abi.encodeWithSelector(CreditPaymaster.RootMismatch.selector, badRoot, storedRoot)
        );
        creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
    }

    function test_validate_spentNullifier_reverts() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        _buildAndValidate(spender, proof, uopHash);

        // Try to reuse the same nullifier
        bytes32 uopHash2 = bytes32(uint256(0xEF01));
        ISemaphore.SemaphoreProof memory proof2 = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash2);

        PackedUserOperation memory userOp2 = buildCreditUserOp(
            spender, bytes32(0), proof2, uopHash2
        );
        // Scope check will fire first since scope != uopHash2 when we reuse old nullifier with old scope
        // Use a proof where scope/message match but nullifier is reused
        proof2.scope = uint256(uopHash2);
        proof2.message = uint256(uopHash2);
        bytes memory proofEncoded = abi.encode(proof2);
        userOp2.paymasterAndData = abi.encodePacked(
            address(creditPM),
            uint128(200_000),
            uint128(0),
            proofEncoded
        );

        vm.prank(ENTRY_POINT);
        vm.expectRevert(
            abi.encodeWithSelector(CreditPaymaster.NullifierSpent.selector, NULLIFIER)
        );
        creditPM.validatePaymasterUserOp(userOp2, uopHash2, 0);
    }

    function test_validate_wrongScope_reverts() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));

        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);
        proof.scope = uint256(uopHash) + 1; // wrong scope

        PackedUserOperation memory userOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);
        bytes memory proofEncoded = abi.encode(proof);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded
        );

        vm.prank(ENTRY_POINT);
        vm.expectRevert(CreditPaymaster.WrongScope.selector);
        creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
    }

    function test_validate_invalidProof_reverts() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        // Make the mock verifier reject
        verifier.setShouldPass(false);

        PackedUserOperation memory userOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);
        bytes memory proofEncoded = abi.encode(proof);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded
        );

        vm.prank(ENTRY_POINT);
        vm.expectRevert(CreditPaymaster.InvalidProof.selector);
        creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
    }

    function test_validate_gasCapExceeded_reverts() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        PackedUserOperation memory userOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);
        // Set gas limits above MAX_CREDIT_GAS (500_000)
        uint128 bigGas = 400_000;
        userOp.accountGasLimits = bytes32(abi.encodePacked(bigGas, bigGas)); // 800k total

        bytes memory proofEncoded = abi.encode(proof);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded
        );

        // Cache before prank — MAX_CREDIT_GAS() is an external call that would consume prank.
        uint256 cap = creditPM.MAX_CREDIT_GAS();

        vm.prank(ENTRY_POINT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditPaymaster.GasCapExceeded.selector,
                uint256(bigGas) + uint256(bigGas),
                cap
            )
        );
        creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
    }

    function test_validate_anySpenderAddress() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        // spender is unrelated to stealth depositor — this is the privacy property
        (, uint256 validationData) = _buildAndValidate(spender, proof, uopHash);
        assertEq(validationData, 0);
    }

    function test_mirrorRoot_notCreditPool_reverts() public {
        vm.expectRevert(CreditPaymaster.NotCreditPool.selector);
        creditPM.mirrorRoot(12345);
    }

    function test_validate_notEntryPoint_reverts() public {
        uint256 poolRoot = _fullBootstrap();
        bytes32 uopHash = bytes32(uint256(0xABCD));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);
        PackedUserOperation memory userOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);

        vm.expectRevert(CreditPaymaster.NotEntryPoint.selector);
        creditPM.validatePaymasterUserOp(userOp, uopHash, 0);
    }
}
