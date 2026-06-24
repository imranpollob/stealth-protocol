// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICreditPool {
    event Deposited(uint256 indexed commitment, uint256 newRoot);

    function deposit(uint256 commitment) external;
    function currentRoot() external view returns (uint256);
    function treeSize() external view returns (uint256);
}
