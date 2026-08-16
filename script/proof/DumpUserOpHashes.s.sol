// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FunctionalCorrectnessFixture} from "../../test/FunctionalCorrectnessFixture.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Phase 1 of the functional-correctness proof pipeline.
///
///         Deploys the fixture deterministically and writes the EntryPoint-computed hash of
///         each fixture UserOperation to test/fixtures/functional-correctness-ops.json.
///         Phase 2 (script/proof/generateFunctionalCorrectnessProofs.mjs) generates genuine
///         Semaphore/Groth16 proofs whose `message` is one of these hashes. Phase 3
///         (test/FunctionalCorrectness.t.sol) replays the identical deployment and asserts
///         the hashes still match before submitting anything.
///
///         Note the operation hashes do not depend on the credit commitments: the Merkle root
///         is paymaster state, not a UserOperation field. So the pool need not be populated here.
///
///         Run from the repo root:
///           forge script script/proof/DumpUserOpHashes.s.sol:DumpUserOpHashes
contract DumpUserOpHashes is Script, FunctionalCorrectnessFixture {
    function run() external {
        _deployAll();

        PackedUserOperation memory accept = opAccept();
        PackedUserOperation memory second = opSecond();
        PackedUserOperation memory otherSender = opOtherSender();
        PackedUserOperation memory overBudget = opOverBudget();

        bytes32 hAccept = entryPoint.getUserOpHash(accept);
        bytes32 hSecond = entryPoint.getUserOpHash(second);
        bytes32 hOtherSender = entryPoint.getUserOpHash(otherSender);
        bytes32 hOverBudget = entryPoint.getUserOpHash(overBudget);

        require(hAccept != hSecond, "dump: accept/second hashes must differ");
        require(hAccept != hOtherSender, "dump: accept/otherSender hashes must differ");
        require(hAccept != hOverBudget, "dump: accept/overBudget hashes must differ");

        string memory obj = "ops";
        vm.serializeUint(obj, "chainId", FIXTURE_CHAIN_ID);
        vm.serializeUint(obj, "groupSize", GROUP_SIZE);
        vm.serializeUint(obj, "scope", CREDIT_NULLIFIER_SCOPE);
        vm.serializeAddress(obj, "entryPoint", address(entryPoint));
        vm.serializeAddress(obj, "creditPaymaster", address(creditPM));
        vm.serializeAddress(obj, "accountA", address(accountA));
        vm.serializeAddress(obj, "accountB", address(accountB));
        vm.serializeBytes32(obj, "opAccept", hAccept);
        vm.serializeBytes32(obj, "opSecond", hSecond);
        vm.serializeBytes32(obj, "opOtherSender", hOtherSender);
        string memory json = vm.serializeBytes32(obj, "opOverBudget", hOverBudget);

        vm.writeJson(json, "./test/fixtures/functional-correctness-ops.json");

        console.log("Wrote test/fixtures/functional-correctness-ops.json");
        console.log("  entryPoint     :", address(entryPoint));
        console.log("  creditPaymaster:", address(creditPM));
        console.log("  accountA       :", address(accountA));
        console.log("  accountB       :", address(accountB));
        console.logBytes32(hAccept);
        console.logBytes32(hSecond);
        console.logBytes32(hOtherSender);
        console.logBytes32(hOverBudget);
    }
}
