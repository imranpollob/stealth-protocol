// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Minimal ERC-4337 account for testing simulateValidation.
///         Accepts any UserOp from its EntryPoint; pays missingAccountFunds if requested.
contract MockAccount is IAccount {
    address public immutable entryPoint;

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    function validateUserOp(
        PackedUserOperation calldata,
        bytes32,
        uint256 missingAccountFunds
    ) external override returns (uint256 validationData) {
        require(msg.sender == entryPoint, "MockAccount: not EP");
        if (missingAccountFunds > 0) {
            (bool ok,) = msg.sender.call{value: missingAccountFunds}("");
            require(ok, "MockAccount: prefund failed");
        }
        return 0; // SIG_VALIDATION_SUCCESS
    }

    receive() external payable {}
}
