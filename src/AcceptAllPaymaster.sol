// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @title AcceptAllPaymaster
/// @notice Minimal validation-gas baseline. Not a production paymaster.
contract AcceptAllPaymaster is IPaymaster {
    address public immutable entryPoint;

    error NotEntryPoint();

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata,
        bytes32,
        uint256
    ) external view override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        return ("", 0);
    }

    function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {}
}
