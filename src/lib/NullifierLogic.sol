// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Pure nullifier-checking logic, substrate-agnostic.
///         CreditPaymaster delegates to this library so the spend policy is
///         not buried inside the ERC-4337-specific entry point.
library NullifierLogic {
    error NullifierAlreadySpent(uint256 nullifierHash);

    function isSpent(mapping(uint256 => bool) storage nullifiers, uint256 nullifierHash)
        internal
        view
        returns (bool)
    {
        return nullifiers[nullifierHash];
    }

    /// @dev Reverts if the nullifier was already recorded; otherwise records it.
    function checkAndMark(mapping(uint256 => bool) storage nullifiers, uint256 nullifierHash) internal {
        if (nullifiers[nullifierHash]) revert NullifierAlreadySpent(nullifierHash);
        nullifiers[nullifierHash] = true;
    }
}
