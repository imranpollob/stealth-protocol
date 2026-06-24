// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {EligibilityLogic} from "./lib/EligibilityLogic.sol";

/// @title BootstrapPaymaster
/// @notice ERC-4337 v0.7 paymaster that sponsors exactly ONE transaction per
///         eligible stealth address: the CreditPool.deposit(commitment) call.
///
///         ERC-7562 compliance:
///         - validatePaymasterUserOp reads ONLY this contract's own storage
///           (_eligible, _used). Eligibility data is pushed here from
///           AnnouncementRegistry via mirrorEligible() — no external SLOADs.
///         - Banned opcodes (TIMESTAMP, NUMBER, ORIGIN, BASEFEE, etc.) are
///           not used anywhere in the validation path.
///         - This contract must be staked at the EntryPoint before going live.
///
///         Sybil-resistance: sponsoring only CreditPool.deposit means an
///         attacker who self-announces gets exactly one free deposit tx —
///         they still must fund a stealth address with >= vMin ETH first.
contract BootstrapPaymaster is IPaymaster {
    using UserOperationLib for PackedUserOperation;

    address public immutable entryPoint;
    address public immutable registry; // AnnouncementRegistry — only caller allowed for mirrorEligible

    // Mirrored state (own storage only — ERC-7562 compliant)
    mapping(address => bool) private _eligible;
    mapping(address => bool) private _used;

    // selector of CreditPool.deposit(uint256)
    bytes4 private immutable _depositSelector;

    error NotEntryPoint();
    error NotRegistry();
    error NotEligible(address sender);
    error AlreadyUsed(address sender);
    error WrongCallTarget();

    event EligibilityMirrored(address indexed stealthAddress);
    event BootstrapSponsored(address indexed stealthAddress);

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    /// @param _entryPoint  ERC-4337 v0.7 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
    /// @param _registry    AnnouncementRegistry address
    /// @param depositSel   bytes4 selector of CreditPool.deposit(uint256)
    constructor(address _entryPoint, address _registry, bytes4 depositSel) {
        entryPoint = _entryPoint;
        registry = _registry;
        _depositSelector = depositSel;
    }

    /// @notice Called by AnnouncementRegistry.announceAndFund() to push eligibility
    ///         into this contract's own storage. This is the "mirror-and-stake" pattern
    ///         required by ERC-7562.
    function mirrorEligible(address stealthAddress) external {
        if (msg.sender != registry) revert NotRegistry();
        _eligible[stealthAddress] = true;
        emit EligibilityMirrored(stealthAddress);
    }

    /// @notice ERC-4337 paymaster validation. Reads only own storage (_eligible, _used).
    ///         Sponsors iff: sender is eligible, hasn't used bootstrap yet, and callData
    ///         targets exactly CreditPool.deposit(uint256).
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, /* userOpHash */
        uint256 /* maxCost */
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        address sender = userOp.sender;

        if (!EligibilityLogic.checkBootstrapEligible(
            _eligible[sender],
            _used[sender],
            userOp.callData,
            _depositSelector
        )) {
            // Return SIG_VALIDATION_FAILED (1 in low bits) to signal rejection.
            return ("", 1);
        }

        // Mark used during validation to prevent double-sponsoring.
        // Note: if the subsequent deposit() reverts, the user loses their free-gas
        // attempt but retains the ability to call deposit() self-funded, since
        // CreditPool.deposit() enforces its own eligibility check independently.
        _used[sender] = true;

        emit BootstrapSponsored(sender);

        // Empty context — postOp will not be called.
        return ("", 0);
    }

    /// @dev Required by IPaymaster. Not called when context is empty.
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {}

    // ── View helpers ────────────────────────────────────────────────────────

    function isEligible(address addr) external view returns (bool) {
        return _eligible[addr];
    }

    function isUsed(address addr) external view returns (bool) {
        return _used[addr];
    }
}
