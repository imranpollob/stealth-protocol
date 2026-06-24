// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Minimal ERC-4337 account that always validates successfully.
contract MockSimpleAccount is IAccount {
    address public immutable entryPoint;

    constructor(address _ep) {
        entryPoint = _ep;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingFunds)
        external
        override
        returns (uint256)
    {
        if (missingFunds > 0) {
            payable(msg.sender).transfer(missingFunds);
        }
        return 0; // SIG_VALIDATION_SUCCESS
    }

    receive() external payable {}

    fallback() external payable {}
}
