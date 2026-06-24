// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal ERC-5564 Announcer interface.
///      Canonical mainnet deployment: 0x55649E01B5Df198D18D95b5cc5051630cfD45564
interface IERC5564Announcer {
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes ephemeralPubKey,
        bytes metadata
    );

    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external;
}
