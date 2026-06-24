// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAnnouncementRegistry {
    event Funded(address indexed stealthAddress, uint256 forwarded, uint256 feeBurned);
    event NonRefundableFeeUpdated(uint256 oldFee, uint256 newFee);

    function announceAndFund(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external payable;

    function eligible(address stealthAddress) external view returns (bool);
    function vMin() external view returns (uint256);
    function nonRefundableFee() external view returns (uint256);
}
