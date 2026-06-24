// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {MockAnnouncer} from "./mock/MockAnnouncer.sol";
import {MockSemaphoreVerifier} from "./mock/MockSemaphoreVerifier.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";

abstract contract TestBase is Test {
    // Canonical ERC-4337 v0.7 EntryPoint address (simulated via prank)
    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    uint256 internal constant V_MIN = 0.01 ether;
    uint256 internal constant SCHEME_ID = 1;

    MockAnnouncer internal announcer;
    MockSemaphoreVerifier internal verifier;
    AnnouncementRegistry internal registry;
    BootstrapPaymaster internal bootstrapPM;
    CreditPool internal creditPool;
    CreditPaymaster internal creditPM;

    address internal deployer = makeAddr("deployer");
    address internal sender = makeAddr("sender");      // funds the stealth address
    address internal stealth = makeAddr("stealth");    // the stealth address recipient
    address internal spender = makeAddr("spender");    // unrelated spending address

    function setUp() public virtual {
        vm.deal(deployer, 100 ether);
        vm.deal(sender, 100 ether);
        vm.deal(stealth, 1 ether);
        vm.deal(spender, 10 ether);

        vm.startPrank(deployer);

        announcer = new MockAnnouncer();
        verifier = new MockSemaphoreVerifier(true);

        // Deploy paymasters first with placeholder addresses, then wire up via constructor
        // The circular dependency (registry→paymasters, pool→creditPM) is resolved by
        // deploying in order: creditPM → creditPool → bootstrapPM → registry

        // Deploy CreditPaymaster (needs creditPool address — use CREATE2-predictable address)
        // Simplest approach: deploy with a temporary placeholder and override in tests that need it.
        // For tests we deploy in dependency order using vm.prank + pre-computed addresses.

        // 1. Pre-compute all addresses using nonces
        uint64 nonce = vm.getNonce(deployer);

        address creditPMAddr = vm.computeCreateAddress(deployer, nonce);
        address creditPoolAddr = vm.computeCreateAddress(deployer, nonce + 1);
        address bootstrapPMAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address registryAddr = vm.computeCreateAddress(deployer, nonce + 3);

        // 2. Deploy in order (addresses must match pre-computed)
        creditPM = new CreditPaymaster(ENTRY_POINT, creditPoolAddr, address(verifier));
        creditPool = new CreditPool(creditPMAddr, registryAddr);
        bootstrapPM = new BootstrapPaymaster(
            ENTRY_POINT,
            registryAddr,
            CreditPool.deposit.selector
        );
        registry = new AnnouncementRegistry(
            address(announcer),
            bootstrapPMAddr,
            creditPoolAddr,
            V_MIN
        );

        vm.stopPrank();
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// Build a minimal PackedUserOperation targeting CreditPool.deposit(commitment).
    function buildDepositUserOp(address _sender, uint256 commitment)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = _sender;
        userOp.nonce = 0;
        userOp.callData = abi.encodeCall(CreditPool.deposit, (commitment));
        // accountGasLimits = verificationGasLimit(high128) || callGasLimit(low128)
        userOp.accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(200_000)));
        userOp.preVerificationGas = 21_000;
        userOp.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        userOp.paymasterAndData = abi.encodePacked(
            address(bootstrapPM),
            uint128(100_000), // paymasterVerificationGasLimit
            uint128(0)        // paymasterPostOpGasLimit
            // no extra data needed for BootstrapPaymaster
        );
    }

    /// Build a PackedUserOperation for CreditPaymaster with an encoded SemaphoreProof.
    function buildCreditUserOp(
        address _sender,
        bytes32 _callData,
        ISemaphore.SemaphoreProof memory proof,
        bytes32 userOpHashHint  // used to set scope/message consistently before encoding
    ) internal view returns (PackedUserOperation memory userOp) {
        userOp.sender = _sender;
        userOp.nonce = 0;
        userOp.callData = abi.encodePacked(_callData); // arbitrary (credit sponsors anything)
        userOp.accountGasLimits = bytes32(abi.encodePacked(uint128(50_000), uint128(100_000)));
        userOp.preVerificationGas = 21_000;
        userOp.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));

        bytes memory proofEncoded = abi.encode(proof);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM),
            uint128(200_000), // paymasterVerificationGasLimit
            uint128(0),       // paymasterPostOpGasLimit
            proofEncoded      // starts at offset 52
        );
        // suppress unused hint warning
        userOpHashHint;
    }

    /// Compute the ERC-4337 userOpHash for a given userOp (chain-agnostic in tests).
    function computeUserOpHash(PackedUserOperation memory userOp) internal view returns (bytes32) {
        return keccak256(abi.encode(keccak256(abi.encode(userOp)), ENTRY_POINT, block.chainid));
    }

    /// Build a SemaphoreProof struct with scope and message both set to userOpHash.
    function buildProof(
        uint256 commitment,
        uint256 nullifier,
        uint256 currentRoot,
        bytes32 userOpHash
    ) internal pure returns (ISemaphore.SemaphoreProof memory proof) {
        uint256 uopHashUint = uint256(userOpHash);
        proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 1,
            merkleTreeRoot: currentRoot,
            nullifier: nullifier,
            message: uopHashUint,
            scope: uopHashUint,
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });
        commitment; // suppress unused warning
    }
}
