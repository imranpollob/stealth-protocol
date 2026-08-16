// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console, stdJson} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {FunctionalCorrectnessFixture} from "./FunctionalCorrectnessFixture.sol";

/// @title FunctionalCorrectness
/// @notice The six functional-correctness cases reported in the PrivGas paper.
///
///         Every case in this file is a full ERC-4337 integration test:
///           - the real `EntryPoint` (account-abstraction v0.9.0) drives validation via
///             `handleOps`, so `userOpHash` and `maxCost` are computed by the EntryPoint
///             from the PackedUserOperation and are never supplied as literals;
///           - the real `SemaphoreVerifier` performs BN254 Groth16 verification on-chain —
///             `MockSemaphoreVerifier` is not used anywhere in this file;
///           - the sender is a real `SimpleAccount` that validates an ECDSA signature over
///             the EntryPoint-computed hash;
///           - every proof is a genuine snarkjs `groth16.fullProve` output over a 4-member
///             Semaphore group (merkleTreeDepth 2), produced by
///             `script/proof/generateFunctionalCorrectnessProofs.mjs`.
///
///         Each test asserts `entryPoint.getUserOpHash(op) == proof.message` before
///         submitting. That assertion is what makes the results defensible: it proves the
///         proof was generated over the hash the EntryPoint actually computes for that exact
///         operation, rather than over an arbitrary value chosen to make the test pass.
///
///         Regenerating the fixtures (see script/proof/README.md):
///           forge script script/proof/DumpUserOpHashes.s.sol:DumpUserOpHashes
///           SEMAPHORE_CORE_PATH=... node script/proof/generateFunctionalCorrectnessProofs.mjs
contract FunctionalCorrectnessTest is Test, FunctionalCorrectnessFixture {
    using stdJson for string;

    string internal json;

    ISemaphore.SemaphoreProof internal proofAccept;
    ISemaphore.SemaphoreProof internal proofSecond;
    ISemaphore.SemaphoreProof internal proofOverBudget;

    uint256 internal creditNullifier;
    uint256 internal fixtureRoot;
    address payable internal beneficiary;

    function setUp() public {
        _deployAll();

        json = vm.readFile("test/fixtures/functional-correctness-proofs.json");
        proofAccept = _loadProof(".proofs.accept");
        proofSecond = _loadProof(".proofs.second");
        proofOverBudget = _loadProof(".proofs.overBudget");
        creditNullifier = json.readUint(".nullifier");
        fixtureRoot = json.readUint(".groupRoot");

        beneficiary = payable(address(uint160(uint256(keccak256("privgas.fc.beneficiary")))));

        // ── Populate the credit pool ────────────────────────────────────────
        // GROUP_SIZE stealth addresses each go through announceAndFund and deposit one
        // commitment. Insertion order matches the JS group, so the on-chain LeanIMT root
        // must equal the root the proofs were generated against.
        vm.deal(FUNDER, 100 ether);
        for (uint256 i = 0; i < GROUP_SIZE; i++) {
            address depositor = _depositor(i);
            uint256 commitment = json.readUint(string.concat(".commitments[", vm.toString(i), "]"));

            vm.prank(FUNDER);
            registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
                SCHEME_ID, depositor, bytes("ephemeralPubKey"), bytes("")
            );

            vm.prank(depositor);
            creditPool.deposit(commitment);
        }

        assertEq(creditPool.treeSize(), GROUP_SIZE, "pool must hold GROUP_SIZE credits");
        assertEq(creditPool.currentRoot(), fixtureRoot, "on-chain LeanIMT root must match the JS group root");
        assertEq(creditPM.merkleRoot(), fixtureRoot, "paymaster mirrored root must match");

        // Fund the paymaster's EntryPoint deposit so it can cover every prefund below.
        vm.deal(address(this), 100 ether);
        entryPoint.depositTo{value: 10 ether}(address(creditPM));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Valid genuine Groth16 proof + unspent nullifier + correct sender -> ACCEPT
    // ─────────────────────────────────────────────────────────────────────────
    function test_validProof_unspentNullifier_correctSender_accepted() public {
        PackedUserOperation memory op = _prepare(opAccept(), proofAccept, OWNER_A_KEY);

        assertFalse(creditPM.isNullifierSpent(creditNullifier), "nullifier must start unspent");
        uint256 depositBefore = entryPoint.balanceOf(address(creditPM));

        _handleOps(op);

        assertEq(target.counter(), 1, "sponsored call must have executed");
        assertTrue(creditPM.isNullifierSpent(creditNullifier), "nullifier must be consumed");
        assertLt(
            entryPoint.balanceOf(address(creditPM)), depositBefore, "paymaster deposit must have been charged"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Valid genuine proof, previously spent nullifier -> REJECT
    // ─────────────────────────────────────────────────────────────────────────
    //  Both proofs are genuine and independently valid. Because the Semaphore scope is
    //  fixed to CREDIT_NULLIFIER_SCOPE, the same credit yields the same nullifier for
    //  both operations, so the second submission is a true double-spend of one credit.
    function test_validProof_previouslySpentNullifier_rejected() public {
        _handleOps(_prepare(opAccept(), proofAccept, OWNER_A_KEY));
        assertTrue(creditPM.isNullifierSpent(creditNullifier), "first spend must consume the nullifier");

        assertEq(proofSecond.nullifier, proofAccept.nullifier, "both proofs must reveal the same credit nullifier");

        PackedUserOperation memory op = _prepare(opSecond(), proofSecond, OWNER_A_KEY);

        _expectPaymasterRevert(abi.encodeWithSelector(CreditPaymaster.NullifierSpent.selector, creditNullifier));
        _handleOps(op);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Valid genuine proof bound to a different sender -> REJECT
    // ─────────────────────────────────────────────────────────────────────────
    //  opOtherSender differs from opAccept in exactly one field: `sender`. Since `sender`
    //  is part of the EIP-712 PackedUserOperation typehash, it changes the userOpHash and
    //  therefore the digest the proof commits to.
    //
    //  Both halves are checked:
    //    (a) submitted as generated -> the paymaster's digest equality check rejects it;
    //    (b) with `message` overwritten to the new operation's hash so that equality check
    //        passes -> on-chain Groth16 verification rejects it. (b) is what shows the
    //        sender binding is enforced by the proof itself, not only by an == comparison.
    function test_validProof_senderMismatch_rejected() public {
        PackedUserOperation memory op = opOtherSender();
        bytes32 otherHash = entryPoint.getUserOpHash(op);
        assertTrue(otherHash != bytes32(proofAccept.message), "changing sender must change the operation hash");

        // (a) unaltered proof -> digest mismatch
        PackedUserOperation memory opA = _attach(op, proofAccept);
        opA = _sign(opA, OWNER_B_KEY);
        _expectPaymasterRevert(abi.encodeWithSelector(CreditPaymaster.WrongMessage.selector));
        _handleOps(opA);

        // (b) digest forced to match -> Groth16 rejects
        ISemaphore.SemaphoreProof memory forged = proofAccept;
        forged.message = uint256(otherHash);
        PackedUserOperation memory opB = _attach(opOtherSender(), forged);
        opB = _sign(opB, OWNER_B_KEY);
        _expectPaymasterRevert(abi.encodeWithSelector(CreditPaymaster.InvalidProof.selector));
        _handleOps(opB);

        assertFalse(creditPM.isNullifierSpent(creditNullifier), "a rejected spend must not consume the credit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Valid genuine proof bound to a different UserOperation -> REJECT
    // ─────────────────────────────────────────────────────────────────────────
    //  Same sender, different operation (different nonce key and callData). Structurally
    //  identical to case 3 but isolating the operation payload rather than the sender.
    function test_validProof_differentUserOperation_rejected() public {
        PackedUserOperation memory op = opSecond();
        bytes32 secondHash = entryPoint.getUserOpHash(op);
        assertTrue(secondHash != bytes32(proofAccept.message), "a different operation must have a different hash");

        // (a) proof bound to opAccept, submitted with opSecond
        PackedUserOperation memory opA = _sign(_attach(op, proofAccept), OWNER_A_KEY);
        _expectPaymasterRevert(abi.encodeWithSelector(CreditPaymaster.WrongMessage.selector));
        _handleOps(opA);

        // (b) digest forced to match -> Groth16 rejects
        ISemaphore.SemaphoreProof memory forged = proofAccept;
        forged.message = uint256(secondHash);
        PackedUserOperation memory opB = _sign(_attach(opSecond(), forged), OWNER_A_KEY);
        _expectPaymasterRevert(abi.encodeWithSelector(CreditPaymaster.InvalidProof.selector));
        _handleOps(opB);

        assertFalse(creditPM.isNullifierSpent(creditNullifier), "a rejected spend must not consume the credit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Unaccepted Merkle root -> REJECT
    // ─────────────────────────────────────────────────────────────────────────
    //  A fifth credit is deposited, advancing the pool root. The proof remains genuine and
    //  internally valid, but its merkleTreeRoot is no longer the root the paymaster accepts.
    function test_unacceptedMerkleRoot_rejected() public {
        address latecomer = _depositor(GROUP_SIZE);
        vm.prank(FUNDER);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID, latecomer, bytes("ephemeralPubKey"), bytes("")
        );
        vm.prank(latecomer);
        creditPool.deposit(uint256(keccak256("privgas.fc.latecomer.commitment")) >> 8);

        uint256 newRoot = creditPM.merkleRoot();
        assertTrue(newRoot != fixtureRoot, "the pool root must have advanced");

        PackedUserOperation memory op = _prepare(opAccept(), proofAccept, OWNER_A_KEY);

        _expectPaymasterRevert(
            abi.encodeWithSelector(CreditPaymaster.RootMismatch.selector, proofAccept.merkleTreeRoot, newRoot)
        );
        _handleOps(op);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. maxCost exceeds the sponsorship budget -> REJECT
    // ─────────────────────────────────────────────────────────────────────────
    //  The operation carries a genuine, valid proof bound to its own hash, so nothing but
    //  the budget check can reject it. maxCost is the EntryPoint's requiredPrefund, computed
    //  from all five gas terms; the operation inflates paymasterVerificationGasLimit, which
    //  the pre-existing MAX_CREDIT_GAS check does not cover.
    function test_maxCostExceedsSponsorshipBudget_rejected() public {
        PackedUserOperation memory op = _prepare(opOverBudget(), proofOverBudget, OWNER_A_KEY);

        uint256 expectedMaxCost = (
            uint256(VERIFICATION_GAS_LIMIT) + CALL_GAS_LIMIT + OVER_BUDGET_PM_VERIFICATION_GAS_LIMIT
                + PM_POSTOP_GAS_LIMIT + PRE_VERIFICATION_GAS
        ) * MAX_FEE_PER_GAS;

        assertGt(expectedMaxCost, creditPM.MAX_SPONSORSHIP_COST(), "operation must exceed the budget");

        // The pre-existing per-field cap does not catch this operation — the budget check is
        // load-bearing, not redundant.
        assertLe(
            uint256(VERIFICATION_GAS_LIMIT) + CALL_GAS_LIMIT,
            creditPM.MAX_CREDIT_GAS(),
            "MAX_CREDIT_GAS alone must not reject this operation"
        );

        _expectPaymasterRevert(
            abi.encodeWithSelector(
                CreditPaymaster.MaxCostExceeded.selector, expectedMaxCost, creditPM.MAX_SPONSORSHIP_COST()
            )
        );
        _handleOps(op);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pipeline integrity (supporting evidence for the six cases above)
    // ─────────────────────────────────────────────────────────────────────────
    //  The proof lives in the ERC-4337 v0.9 paymaster-signature region, which
    //  paymasterDataKeccak excludes from the userOpHash. Without this property a proof
    //  could not commit to the hash of the operation carrying it.
    function test_operationHashIsIndependentOfProofBytes() public view {
        bytes32 withPlaceholder = entryPoint.getUserOpHash(opAccept());
        bytes32 withRealProof = entryPoint.getUserOpHash(_attach(opAccept(), proofAccept));

        assertEq(withRealProof, withPlaceholder, "proof bytes must not affect the operation hash");
        assertEq(withRealProof, bytes32(proofAccept.message), "proof must commit to this operation's hash");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Attaches the proof, then signs the EntryPoint-computed hash, then asserts the
    ///      proof commits to that same hash. Any drift between the fixture-generation phase
    ///      and this test fails here rather than silently weakening the case.
    function _prepare(PackedUserOperation memory op, ISemaphore.SemaphoreProof memory proof, uint256 ownerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory withProof = _sign(_attach(op, proof), ownerKey);
        assertEq(
            entryPoint.getUserOpHash(withProof),
            bytes32(proof.message),
            "proof.message must equal the EntryPoint-computed userOpHash"
        );
        return withProof;
    }

    function _attach(PackedUserOperation memory op, ISemaphore.SemaphoreProof memory proof)
        internal
        view
        returns (PackedUserOperation memory)
    {
        uint128 pmGas = uint128(bytes16(_slice(op.paymasterAndData, 20, 16)));
        op.paymasterAndData = _paymasterAndData(pmGas, proof);
        return op;
    }

    /// @dev The signature is not covered by the userOpHash, so signing after attaching the
    ///      proof is safe and does not perturb the digest the proof commits to.
    function _sign(PackedUserOperation memory op, uint256 ownerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    /// @dev EntryPoint v0.9's nonReentrant modifier requires `tx.origin == msg.sender` and a
    ///      codeless caller, so operations are submitted by an EOA bundler exactly as a real
    ///      bundler would. `vm.prank(sender, origin)` sets both.
    function _handleOps(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, beneficiary);
    }

    /// @dev The EntryPoint wraps a reverting paymaster as FailedOpWithRevert(0, "AA33 reverted", inner).
    function _expectPaymasterRevert(bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, uint256(0), "AA33 reverted", inner)
        );
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
    }

    function _loadProof(string memory key) internal view returns (ISemaphore.SemaphoreProof memory proof) {
        proof.merkleTreeDepth = json.readUint(string.concat(key, ".merkleTreeDepth"));
        proof.merkleTreeRoot = json.readUint(string.concat(key, ".merkleTreeRoot"));
        proof.nullifier = json.readUint(string.concat(key, ".nullifier"));
        proof.message = json.readUint(string.concat(key, ".message"));
        proof.scope = json.readUint(string.concat(key, ".scope"));
        for (uint256 i = 0; i < 8; i++) {
            proof.points[i] = json.readUint(string.concat(key, ".points[", vm.toString(i), "]"));
        }
    }
}
