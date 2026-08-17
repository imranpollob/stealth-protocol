// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Pure eligibility-checking logic, substrate-agnostic.
///         Paymasters and CreditPool call into this library so the policy is
///         decoupled from the ERC-4337 IPaymaster interface and can be reused
///         under a different transaction format (e.g. EIP-8141 native AA).
library EligibilityLogic {
    /// @dev ABI layout of `execute(address,uint256,bytes)` carrying a 36-byte inner call:
    ///        [0:4]     execute selector
    ///        [4:36]    address target      (right-aligned in the word)
    ///        [36:68]   uint256 value
    ///        [68:100]  offset to bytes     (canonically 0x60)
    ///        [100:132] inner calldata length
    ///        [132:168] inner calldata      (4-byte selector + one uint256 word)
    ///        [168:196] tail padding to a 32-byte boundary
    uint256 private constant EXEC_CALLDATA_LEN = 196;
    uint256 private constant EXEC_BYTES_OFFSET = 0x60;
    uint256 private constant INNER_CALLDATA_LEN = 36;

    /// @return True iff `eligible` is set, `used` is not, and `callData` encodes exactly
    ///         `execute(creditPool, 0, deposit(uint256))` on the sender account.
    ///
    ///         ERC-4337 executes `callData` on `userOp.sender`, so a bootstrap operation
    ///         must be an account execution wrapping the pool call — not the pool call
    ///         itself. Every field of that wrapper is pinned here (selector, target, zero
    ///         value, canonical bytes offset, inner length, inner selector) so the free
    ///         sponsorship cannot be redirected to any other call. The single uint256
    ///         argument at [136:168] is the depositor's commitment and is intentionally
    ///         unconstrained.
    function checkBootstrapEligible(
        bool eligible,
        bool used,
        bytes calldata callData,
        bytes4 executeSelector,
        address creditPool,
        bytes4 depositSelector
    ) internal pure returns (bool) {
        if (!eligible || used) return false;

        if (callData.length != EXEC_CALLDATA_LEN) return false;
        if (bytes4(callData[:4]) != executeSelector) return false;

        // target must be exactly the configured CreditPool
        if (address(uint160(uint256(bytes32(callData[4:36])))) != creditPool) return false;
        // no ETH may ride along
        if (uint256(bytes32(callData[36:68])) != 0) return false;
        // canonical encoding only — pins the inner call to [132:168]
        if (uint256(bytes32(callData[68:100])) != EXEC_BYTES_OFFSET) return false;
        if (uint256(bytes32(callData[100:132])) != INNER_CALLDATA_LEN) return false;
        // inner call must be deposit(uint256)
        if (bytes4(callData[132:136]) != depositSelector) return false;

        return true;
    }

    /// @return True iff `eligible` is set and `used` is not.
    ///         Used by CreditPool.deposit() to enforce V_MIN invariant:
    ///         only addresses that went through announceAndFund may deposit.
    function checkDepositEligible(bool eligible, bool used) internal pure returns (bool) {
        return eligible && !used;
    }
}
