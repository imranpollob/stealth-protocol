// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC5564Announcer} from "../../src/interfaces/IERC5564Announcer.sol";

contract MockAnnouncer is IERC5564Announcer {
    event AnnounceCalled(uint256 schemeId, address stealthAddress);

    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata,
        bytes calldata
    ) external override {
        emit AnnounceCalled(schemeId, stealthAddress);
    }
}
