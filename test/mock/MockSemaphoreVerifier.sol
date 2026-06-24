// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISemaphoreVerifier} from "@semaphore-protocol/contracts/interfaces/ISemaphoreVerifier.sol";

/// @dev Configurable mock: returns `shouldPass` for every verifyProof call.
contract MockSemaphoreVerifier is ISemaphoreVerifier {
    bool public shouldPass;

    constructor(bool _shouldPass) {
        shouldPass = _shouldPass;
    }

    function setShouldPass(bool v) external {
        shouldPass = v;
    }

    function verifyProof(
        uint[2] calldata,
        uint[2][2] calldata,
        uint[2] calldata,
        uint[4] calldata,
        uint
    ) external view override returns (bool) {
        return shouldPass;
    }
}
