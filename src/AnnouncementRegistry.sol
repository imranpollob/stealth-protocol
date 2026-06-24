// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC5564Announcer} from "./interfaces/IERC5564Announcer.sol";
import {IAnnouncementRegistry} from "./interfaces/IAnnouncementRegistry.sol";

interface IEligibilityMirror {
    function mirrorEligible(address stealthAddress) external;
}

/// @title AnnouncementRegistry
/// @notice Payable wrapper around an ERC-5564 Announcer that ties sponsorship
///         eligibility to a genuine, irrecoverable on-chain cost.
///
///         Each announceAndFund() call requires msg.value >= vMin + nonRefundableFee:
///           - vMin is forwarded to stealthAddress (funds bootstrap gas)
///           - nonRefundableFee is burned to address(0) — irrecoverable even in
///             self-dealing attacks where the caller controls stealthAddress
///
///         Sybil-resistance invariant (must hold after any fee update):
///           nonRefundableFee > kappa * c_credit
///         where c_credit = MAX_CREDIT_GAS enforced by CreditPaymaster, kappa > 1.
///         Both terms are in ETH (wei) at the anchor gas price.
///         The old V_MIN > c_ann + kappa*c_credit invariant broke because V_MIN was
///         fully refundable via a self-dealing round trip; nonRefundableFee is not.
contract AnnouncementRegistry is IAnnouncementRegistry {
    IERC5564Announcer public immutable announcer;
    IEligibilityMirror public immutable bootstrapPaymaster;
    IEligibilityMirror public immutable creditPool;

    address public owner;
    uint256 public vMin;
    // Permanently burned on each announcement — the genuine Sybil cost.
    // Invariant: nonRefundableFee > kappa * MAX_CREDIT_GAS (in ETH at anchor gas price).
    uint256 public nonRefundableFee;

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

    /// @param _announcer        ERC-5564 Announcer (0x55649E01B5Df198D18D95b5cc5051630cfD45564 mainnet)
    /// @param _bootstrapPM      BootstrapPaymaster address
    /// @param _creditPool       CreditPool address
    /// @param _vMin             Minimum ETH forwarded to the stealth address (wei)
    /// @param _nonRefundableFee ETH permanently burned on each announcement (wei)
    constructor(
        address _announcer,
        address _bootstrapPM,
        address _creditPool,
        uint256 _vMin,
        uint256 _nonRefundableFee
    ) {
        if (_announcer == address(0) || _bootstrapPM == address(0) || _creditPool == address(0)) {
            revert ZeroAddress();
        }
        announcer = IERC5564Announcer(_announcer);
        bootstrapPaymaster = IEligibilityMirror(_bootstrapPM);
        creditPool = IEligibilityMirror(_creditPool);
        owner = msg.sender;
        vMin = _vMin;
        nonRefundableFee = _nonRefundableFee;
    }

    /// @notice Atomically: burn nonRefundableFee, forward remaining ETH to stealthAddress,
    ///         announce it on ERC-5564, and mark it eligible for gas sponsorship.
    ///         msg.value must be >= vMin + nonRefundableFee.
    function announceAndFund(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external payable override {
        uint256 required = vMin + nonRefundableFee;
        if (msg.value < required) revert BelowVMin(msg.value, required);

        // 1. Burn the non-refundable fee to address(0) — unspendable on any EVM chain.
        //    This is the genuine Sybil cost: irrecoverable even if msg.sender == stealthAddress.
        (bool burnOk,) = address(0).call{value: nonRefundableFee}("");
        if (!burnOk) revert ETHForwardFailed();

        // 2. Forward remaining ETH to stealthAddress.
        uint256 forwardAmount = msg.value - nonRefundableFee;
        (bool ok,) = stealthAddress.call{value: forwardAmount}("");
        if (!ok) revert ETHForwardFailed();

        // 3. Announce via underlying ERC-5564 Announcer.
        announcer.announce(schemeId, stealthAddress, ephemeralPubKey, metadata);

        // 4. Record eligibility in own storage.
        eligible[stealthAddress] = true;

        // 5. Push to BootstrapPaymaster's mirrored storage (ERC-7562: paymaster reads own storage).
        bootstrapPaymaster.mirrorEligible(stealthAddress);

        // 6. Push to CreditPool's mirrored storage (deposit() enforces its own check
        //    without an external SLOAD into this contract).
        creditPool.mirrorEligible(stealthAddress);

        emit Funded(stealthAddress, forwardAmount, nonRefundableFee);
    }

    function setVMin(uint256 newVMin) external onlyOwner {
        emit VMinUpdated(vMin, newVMin);
        vMin = newVMin;
    }

    function setNonRefundableFee(uint256 newFee) external onlyOwner {
        emit NonRefundableFeeUpdated(nonRefundableFee, newFee);
        nonRefundableFee = newFee;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
