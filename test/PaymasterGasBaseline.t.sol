// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.t.sol";
import {AcceptAllPaymaster} from "../src/AcceptAllPaymaster.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract PaymasterGasBaselineTest is TestBase {
    uint256 internal constant COMMITMENT = 515151;
    uint256 internal constant NULLIFIER = 616161;

    AcceptAllPaymaster internal acceptAllPM;

    function setUp() public override {
        super.setUp();

        vm.prank(deployer);
        acceptAllPM = new AcceptAllPaymaster(ENTRY_POINT);
    }

    function test_validationGas_acceptAll_vs_bootstrap_vs_credit() public {
        PackedUserOperation memory acceptOp = buildDepositUserOp(stealth, COMMITMENT);
        acceptOp.paymasterAndData = abi.encodePacked(
            address(acceptAllPM),
            uint128(100_000),
            uint128(0)
        );

        vm.prank(ENTRY_POINT);
        uint256 gasBefore = gasleft();
        (, uint256 acceptValidation) = acceptAllPM.validatePaymasterUserOp(acceptOp, bytes32(0), 0);
        uint256 acceptGas = gasBefore - gasleft();
        assertEq(acceptValidation, 0);

        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, stealth, bytes("pk"), bytes("")
        );

        PackedUserOperation memory bootstrapOp = buildDepositUserOp(stealth, COMMITMENT);

        vm.prank(ENTRY_POINT);
        gasBefore = gasleft();
        (, uint256 bootstrapValidation) = bootstrapPM.validatePaymasterUserOp(bootstrapOp, bytes32(0), 0);
        uint256 bootstrapGas = gasBefore - gasleft();
        assertEq(bootstrapValidation, 0);

        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        uint256 poolRoot = creditPool.currentRoot();
        bytes32 uopHash = bytes32(uint256(0x123456));
        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);
        PackedUserOperation memory creditOp = buildCreditUserOp(spender, bytes32(0), proof, uopHash);

        vm.prank(ENTRY_POINT);
        gasBefore = gasleft();
        (, uint256 creditValidation) = creditPM.validatePaymasterUserOp(creditOp, uopHash, 0);
        uint256 creditGas = gasBefore - gasleft();
        assertEq(creditValidation, 0);

        console.log("AcceptAllPaymaster validation gas:", acceptGas);
        console.log("BootstrapPaymaster validation gas:", bootstrapGas);
        console.log("CreditPaymaster validation gas:", creditGas);
    }
}
