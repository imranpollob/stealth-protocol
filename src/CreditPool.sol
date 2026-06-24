// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InternalLeanIMT, LeanIMTData} from "@zk-kit/lean-imt.sol/InternalLeanIMT.sol";
import {ICreditPool} from "./interfaces/ICreditPool.sol";
import {EligibilityLogic} from "./lib/EligibilityLogic.sol";

interface IRootMirror {
    function mirrorRoot(uint256 root) external;
}

/// @title CreditPool
/// @notice Incremental Merkle tree of Semaphore v4 identity commitments ("credits").
///         Each depositor is a stealth-address recipient who has been funded via
///         AnnouncementRegistry.announceAndFund() (>= vMin ETH). The deposit records
///         a commitment that later authorises an anonymous spend through CreditPaymaster.
///
///         Commitment semantics (Semaphore v4):
///         The leaf inserted is a Semaphore v4 identity commitment:
///           commitment = Poseidon(EdDSA_public_key over Baby Jubjub)
///         Generated off-chain by the semaphore-protocol/identity v4 SDK.
///         It is NOT derived from the stealth address's secp256k1 key — the recipient
///         picks an independent random identity for each credit.
///
///         Access control on deposit():
///         Only addresses that received mirrorEligible() from AnnouncementRegistry
///         (i.e., funded a stealth address with >= vMin) may deposit. This is the
///         canonical enforcer of the sybil-resistance invariant:
///           V_MIN > c_ann + kappa * c_credit
///         Without this check a self-funded attacker could call deposit() directly,
///         bypassing BootstrapPaymaster and V_MIN entirely.
///
///         ERC-7562: deposit() is NOT called from a paymaster validation context,
///         so the storage access rules don't apply here.
contract CreditPool is ICreditPool {
    using InternalLeanIMT for LeanIMTData;

    IRootMirror public immutable creditPaymaster;
    address public immutable registry; // AnnouncementRegistry — only caller for mirrorEligible

    LeanIMTData private _tree;

    // Mirrored eligibility (pushed from AnnouncementRegistry)
    mapping(address => bool) private _eligible;
    mapping(address => bool) private _used; // "used" here means "has deposited"

    error NotRegistry();
    error NotEligible(address sender);
    error AlreadyDeposited(address sender);

    event EligibilityMirrored(address indexed stealthAddress);

    /// @param _creditPaymaster  CreditPaymaster address (receives mirrorRoot calls)
    /// @param _registry         AnnouncementRegistry address
    constructor(address _creditPaymaster, address _registry) {
        creditPaymaster = IRootMirror(_creditPaymaster);
        registry = _registry;
    }

    /// @notice Called by AnnouncementRegistry to mark a stealth address as eligible
    ///         to deposit. Keeps deposit()'s eligibility check within this contract's
    ///         own storage (no external SLOAD needed in any paymaster path).
    function mirrorEligible(address stealthAddress) external {
        if (msg.sender != registry) revert NotRegistry();
        _eligible[stealthAddress] = true;
        emit EligibilityMirrored(stealthAddress);
    }

    /// @notice Insert a Semaphore v4 identity commitment into the Merkle tree.
    ///         msg.sender must be an eligible, not-yet-deposited stealth address.
    ///         After insertion the new root is pushed to CreditPaymaster's mirrored storage.
    function deposit(uint256 commitment) external override {
        // Enforce V_MIN invariant: only registry-approved addresses may insert a credit.
        if (!EligibilityLogic.checkDepositEligible(_eligible[msg.sender], _used[msg.sender])) {
            if (!_eligible[msg.sender]) revert NotEligible(msg.sender);
            revert AlreadyDeposited(msg.sender);
        }

        _used[msg.sender] = true;

        uint256 newRoot = _tree._insert(commitment);

        // Push updated root to CreditPaymaster's own storage (ERC-7562 mirror pattern).
        creditPaymaster.mirrorRoot(newRoot);

        emit Deposited(commitment, newRoot);
    }

    function currentRoot() external view override returns (uint256) {
        return _tree._root();
    }

    function treeSize() external view override returns (uint256) {
        return _tree.size;
    }

    function isEligible(address addr) external view returns (bool) {
        return _eligible[addr];
    }

    function hasDeposited(address addr) external view returns (bool) {
        return _used[addr];
    }
}
