// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SemaphoreVerifier} from "@semaphore-protocol/contracts/base/SemaphoreVerifier.sol";

/// @notice Measures the real on-chain gas cost of BN254 Groth16 proof verification
///         using the vendored SemaphoreVerifier.sol (NOT the mock).
///
///         Methodology: supply valid BN254 curve points (G1/G2 generators) as the
///         proof so that ALL precompile calls (ecMul×4, ecAdd×4, ecPairing×1) execute
///         fully. The proof itself is incorrect (it cannot satisfy the circuit's
///         constraints), so verifyProof returns false — but the gas consumed is
///         identical to a valid proof because the EVM does not short-circuit on
///         pairing failure; it runs the full 768-byte pairing and returns a 0/1 result.
///
///         Why generator points are safe:
///           G1 generator (1, 2) is on BN254 G1.
///           G2 generator (gammax*/gammay* constants from SemaphoreVerifier.sol) is on BN254 G2.
///           ecMul/ecAdd/ecPairing precompiles accept these and run without reverting.
contract RealGroth16Test is Test {
    SemaphoreVerifier internal verifier;

    // BN254 G1 generator — valid G1 curve point
    uint256 constant G1X = 1;
    uint256 constant G1Y = 2;

    // BN254 G2 generator — valid G2 curve point
    // (these are the gamma2 constants hard-coded in SemaphoreVerifier.sol)
    uint256 constant G2_X0 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant G2_X1 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant G2_Y0 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant G2_Y1 =  8495653923123431417604973247489272438418190587263600148770280649306958101930;

    function setUp() public {
        verifier = new SemaphoreVerifier();
    }

    /// @notice Gas baseline: call verifyProof with valid curve points.
    ///         forge test --gas-report captures function-level gas automatically;
    ///         the gasleft() delta here is also logged to console for reference.
    function test_realVerifyProof_gasBaseline() public view {
        uint[2] memory pA = [G1X, G1Y];
        uint[2][2] memory pB = [[G2_X0, G2_X1], [G2_Y0, G2_Y1]];
        uint[2] memory pC = [G1X, G1Y];
        // pubSignals: [root, nullifier, hash(msg), hash(scope)] — all < BN254 scalar field r
        uint[4] memory pubSignals = [uint256(1), uint256(2), uint256(3), uint256(4)];
        uint256 depth = 1; // MIN_DEPTH

        uint256 gasBefore = gasleft();
        bool result = verifier.verifyProof(pA, pB, pC, pubSignals, depth);
        uint256 gasUsed = gasBefore - gasleft();

        // Proof is deliberately invalid — what we measure is the gas, not correctness
        assertFalse(result, "dummy proof must not verify");
        console.log("SemaphoreVerifier.verifyProof gas (real BN254, depth=1):", gasUsed);
    }

    /// @notice Second call: same proof, depth=16 (typical production tree depth).
    ///         The VK points differ by depth but the pairing cost is constant.
    function test_realVerifyProof_depth16() public view {
        uint[2] memory pA = [G1X, G1Y];
        uint[2][2] memory pB = [[G2_X0, G2_X1], [G2_Y0, G2_Y1]];
        uint[2] memory pC = [G1X, G1Y];
        uint[4] memory pubSignals = [uint256(1), uint256(2), uint256(3), uint256(4)];

        uint256 gasBefore = gasleft();
        bool result = verifier.verifyProof(pA, pB, pC, pubSignals, 16);
        uint256 gasUsed = gasBefore - gasleft();

        assertFalse(result, "dummy proof must not verify");
        console.log("SemaphoreVerifier.verifyProof gas (real BN254, depth=16):", gasUsed);
    }
}
