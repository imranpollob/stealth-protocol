// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC5564Announcer} from "./interfaces/IERC5564Announcer.sol";
import {IAnnouncementRegistry} from "./interfaces/IAnnouncementRegistry.sol";

interface IEligibilityMirror {
    function mirrorEligible(address stealthAddress) external;
}

/// @title AnnouncementRegistry
/// @notice Payable wrapper around an ERC-5564 Announcer that ties sponsorship
///         eligibility to real on-chain ETH transfer.
///
///         The ONLY path to Bootstrap eligibility is announceAndFund():
///         it requires msg.value >= vMin, forwards that ETH to the stealth
///         address in the same transaction, calls the underlying Announcer,
///         and sets eligible[stealthAddress] = true in its own storage.
///
///         Callers who invoke the raw Announcer directly still get a valid,
///         spendable stealth payment — they just don't earn Bootstrap
///         sponsorship. Correctness of the underlying stealth payment is
///         never affected by this registry.
///
///         Sybil-resistance invariant (must hold at deploy time and after any
///         vMin update):
///           V_MIN > c_ann + kappa * c_credit
///         where c_ann = gas cost to self-announce, c_credit = MAX_CREDIT_GAS
///         enforced by CreditPaymaster, kappa > 1.
///         V_MIN is denominated in ETH (wei). c_credit is a fixed gas-unit
///         ceiling, making the invariant independent of gas-price volatility.
contract AnnouncementRegistry is IAnnouncementRegistry {
    IERC5564Announcer public immutable announcer;
    IEligibilityMirror public immutable bootstrapPaymaster;
    IEligibilityMirror public immutable creditPool;

    address public owner;
    uint256 public vMin;

    mapping(address => bool) public eligible;

    error BelowVMin(uint256 sent, uint256 required);
    error ETHForwardFailed();
    error Unauthorized();
    error ZeroAddress();

    event VMinUpdated(uint256 oldVMin, uint256 newVMin);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param _announcer    ERC-5564 Announcer (e.g. 0x55649E01B5Df198D18D95b5cc5051630cfD45564 on mainnet)
    /// @param _bootstrapPM  BootstrapPaymaster address (will receive mirrorEligible calls)
    /// @param _creditPool   CreditPool address (will receive mirrorEligible calls)
    /// @param _vMin         Initial minimum funding threshold in wei
    constructor(
        address _announcer,
        address _bootstrapPM,
        address _creditPool,
        uint256 _vMin
    ) {
        if (_announcer == address(0) || _bootstrapPM == address(0) || _creditPool == address(0)) {
            revert ZeroAddress();
        }
        announcer = IERC5564Announcer(_announcer);
        bootstrapPaymaster = IEligibilityMirror(_bootstrapPM);
        creditPool = IEligibilityMirror(_creditPool);
        owner = msg.sender;
        vMin = _vMin;
    }

    /// @notice Atomically: fund the stealth address, announce it, and mark it eligible.
    ///         msg.value must be >= vMin; entire msg.value is forwarded to stealthAddress.
    function announceAndFund(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external payable override {
        if (msg.value < vMin) revert BelowVMin(msg.value, vMin);

        // 1. Forward ETH — eligibility is tied to ETH the registry itself moved.
        (bool ok,) = stealthAddress.call{value: msg.value}("");
        if (!ok) revert ETHForwardFailed();

        // 2. Announce via underlying ERC-5564 Announcer.
        announcer.announce(schemeId, stealthAddress, ephemeralPubKey, metadata);

        // 3. Record eligibility in own storage.
        eligible[stealthAddress] = true;

        // 4. Push to BootstrapPaymaster's mirrored storage (ERC-7562: paymaster reads own storage).
        bootstrapPaymaster.mirrorEligible(stealthAddress);

        // 5. Push to CreditPool's mirrored storage (so deposit() can enforce the invariant
        //    without an external SLOAD into this contract).
        creditPool.mirrorEligible(stealthAddress);

        emit Funded(stealthAddress, msg.value);
    }

    function setVMin(uint256 newVMin) external onlyOwner {
        emit VMinUpdated(vMin, newVMin);
        vMin = newVMin;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
