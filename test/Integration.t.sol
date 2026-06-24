// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase} from "./TestBase.t.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Full 3-step happy-path integration test.
///
///         Step 1 (announce): sender calls announceAndFund() → stealth address funded,
///                            eligibility propagated to both paymasters.
///         Step 2 (bootstrap): stealth address uses BootstrapPaymaster to get the
///                             CreditPool.deposit() tx sponsored (no ETH needed for gas).
///         Step 3 (spend):    An unrelated spender uses CreditPaymaster with a ZK proof
///                            to get an arbitrary tx sponsored. The stealth depositor and
///                            the spender are unlinkable on-chain.
contract IntegrationTest is TestBase {
    uint256 internal constant COMMITMENT = 424242424242;
    uint256 internal constant NULLIFIER  = 999888777666;

    function test_fullProtocolFlow() public {
        // ── Step 1: Announce and fund ────────────────────────────────────────
        uint256 stealthBalanceBefore = stealth.balance;

        vm.prank(sender);
        registry.announceAndFund{value: V_MIN}(
            SCHEME_ID, stealth, bytes("ephemeralPubKey"), bytes("metadata")
        );

        assertEq(stealth.balance, stealthBalanceBefore + V_MIN, "ETH not forwarded");
        assertTrue(registry.eligible(stealth), "registry eligibility not set");
        assertTrue(bootstrapPM.isEligible(stealth), "bootstrapPM eligibility not mirrored");
        assertTrue(creditPool.isEligible(stealth), "creditPool eligibility not mirrored");

        // ── Step 2: Bootstrap-sponsored deposit ─────────────────────────────
        PackedUserOperation memory depositOp = buildDepositUserOp(stealth, COMMITMENT);

        // EntryPoint calls validatePaymasterUserOp, then executes callData
        vm.prank(ENTRY_POINT);
        (bytes memory ctx, uint256 validationData) =
            bootstrapPM.validatePaymasterUserOp(depositOp, bytes32(uint256(1)), 0);

        assertEq(ctx.length, 0, "unexpected context");
        assertEq(validationData, 0, "bootstrap validation failed");
        assertTrue(bootstrapPM.isUsed(stealth), "stealth not marked used");

        // Simulate EntryPoint executing the deposit callData on behalf of stealth
        vm.prank(stealth);
        creditPool.deposit(COMMITMENT);

        uint256 poolRoot = creditPool.currentRoot();
        assertGt(poolRoot, 0, "pool root not set");
        assertEq(creditPM.merkleRoot(), poolRoot, "credit paymaster root not mirrored");
        assertTrue(creditPool.hasDeposited(stealth), "deposit not recorded");

        // ── Step 3: Anonymous credit spend by unrelated spender ─────────────
        // spender is completely unrelated to stealth — this is the privacy property
        bytes32 uopHash = bytes32(uint256(0xDEADBEEF));

        ISemaphore.SemaphoreProof memory proof = buildProof(COMMITMENT, NULLIFIER, poolRoot, uopHash);

        PackedUserOperation memory spendOp = buildCreditUserOp(
            spender, bytes32(0), proof, uopHash
        );
        bytes memory proofEncoded = abi.encode(proof);
        spendOp.paymasterAndData = abi.encodePacked(
            address(creditPM), uint128(200_000), uint128(0), proofEncoded
        );

        vm.prank(ENTRY_POINT);
        (, uint256 spendValidation) =
            creditPM.validatePaymasterUserOp(spendOp, uopHash, 0);

        assertEq(spendValidation, 0, "credit spend validation failed");
        assertTrue(creditPM.isNullifierSpent(NULLIFIER), "nullifier not marked spent");
    }
}
