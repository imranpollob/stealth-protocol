// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {ISemaphoreVerifier} from "@semaphore-protocol/contracts/interfaces/ISemaphoreVerifier.sol";
import {IERC5564Announcer} from "../src/interfaces/IERC5564Announcer.sol";

/// @notice Mock ERC-5564 Announcer for local demo (no mainnet deploy needed)
contract DemoAnnouncer is IERC5564Announcer {
    function announce(uint256 schemeId, address stealthAddress, bytes calldata ephemeralPubKey, bytes calldata metadata) external {
        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
    }
}

/// @notice Mock verifier for demo (always accepts proof - real proof generation is off-chain)
contract DemoVerifier is ISemaphoreVerifier {
    function verifyProof(uint[2] calldata, uint[2][2] calldata, uint[2] calldata, uint[4] calldata, uint) external pure override returns (bool) {
        return true;
    }
}

/// @title Demo
/// @notice End-to-end demo of the full 3-step stealth-address gas sponsorship protocol.
///
///         Run in Forge simulation mode (no RPC needed; vm.prank drives EntryPoint steps):
///           forge script script/Demo.s.sol:Demo -vv
///
///         Note: PoseidonT3 (29 KB) exceeds EIP-170's 24 KB mainnet limit. For broadcast
///         to a real network use a pre-deployed PoseidonT3 at its canonical address.
///         For Anvil: anvil --code-size-limit 100000 && forge script ... --rpc-url ... --broadcast
///
///         Steps demonstrated:
///           1. ANNOUNCE: sender funds stealth address via AnnouncementRegistry.announceAndFund()
///           2. BOOTSTRAP: stealth address deposits a credit commitment (gas sponsored by BootstrapPaymaster)
///           3. SPEND: unrelated spender gets an arbitrary tx sponsored via CreditPaymaster + ZK proof
contract Demo is Script {
    // Simulated Semaphore v4 identity commitment (off-chain: Poseidon(EdDSA_pubkey))
    uint256 constant DEMO_COMMITMENT = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    // Simulated on-chain nullifier (off-chain: Poseidon(identity_nullifier, CREDIT_NULLIFIER_SCOPE))
    uint256 constant DEMO_NULLIFIER  = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890;
    uint256 constant CREDIT_NULLIFIER_SCOPE = uint256(keccak256("stealth-protocol.credit.v1"));

    uint256 constant V_MIN = 0.01 ether;
    uint256 constant NONREFUNDABLE_FEE = 0.01 ether;
    uint256 constant SCHEME_ID = 1;

    function run() external {
        // Use pre-funded Anvil accounts
        address deployer = vm.addr(1);
        address sender   = vm.addr(2); // funds the stealth address
        address stealth  = vm.addr(3); // stealth address (the recipient)
        address spender  = vm.addr(4); // unrelated address that spends the credit

        address ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

        // Fund accounts for local Anvil (vm.deal is a cheatcode, not a broadcast tx)
        vm.deal(deployer, 10 ether);
        vm.deal(sender,   1 ether);
        vm.deal(stealth,  1 ether);
        vm.deal(spender,  1 ether);

        console.log("=== Stealth Protocol Demo ===");
        console.log("EntryPoint:", ENTRY_POINT);
        console.log("Sender (funds stealth):", sender);
        console.log("Stealth address:", stealth);
        console.log("Spender (unrelated):", spender);
        console.log("");

        // ── Deploy contracts ──────────────────────────────────────────────────
        vm.startBroadcast(deployer);

        DemoAnnouncer announcer = new DemoAnnouncer();
        DemoVerifier verifier = new DemoVerifier();

        uint64 nonce = vm.getNonce(deployer);
        address creditPMAddr   = vm.computeCreateAddress(deployer, nonce);
        address creditPoolAddr = vm.computeCreateAddress(deployer, nonce + 1);
        address bootstrapPMAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address registryAddr   = vm.computeCreateAddress(deployer, nonce + 3);

        CreditPaymaster creditPM = new CreditPaymaster(ENTRY_POINT, creditPoolAddr, address(verifier));
        CreditPool creditPool    = new CreditPool(creditPMAddr, registryAddr);
        BootstrapPaymaster bootstrapPM = new BootstrapPaymaster(
            ENTRY_POINT, registryAddr, CreditPool.deposit.selector
        );
        AnnouncementRegistry registry = new AnnouncementRegistry(
            address(announcer), bootstrapPMAddr, creditPoolAddr, V_MIN, NONREFUNDABLE_FEE
        );

        vm.stopBroadcast();

        console.log("Deployed AnnouncementRegistry:", address(registry));
        console.log("Deployed BootstrapPaymaster:  ", address(bootstrapPM));
        console.log("Deployed CreditPool:          ", address(creditPool));
        console.log("Deployed CreditPaymaster:     ", address(creditPM));
        console.log("");

        // ── Step 1: ANNOUNCE ─────────────────────────────────────────────────
        console.log("--- STEP 1: Announce and Fund ---");
        console.log("Sender calls announceAndFund() - total sent:", (V_MIN + NONREFUNDABLE_FEE) / 1e15, "finney");

        uint256 stealthBefore = stealth.balance;

        vm.broadcast(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID,
            stealth,
            hex"02abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab", // ephemeral pubkey (demo)
            hex"01"  // metadata: first byte = view tag
        );

        console.log("  stealth balance before:", stealthBefore);
        console.log("  stealth balance after: ", stealth.balance);
        console.log("  ETH forwarded:         ", stealth.balance - stealthBefore);
        console.log("  eligible in registry:  ", registry.eligible(stealth));
        console.log("  eligible in bootstrap: ", bootstrapPM.isEligible(stealth));
        console.log("  eligible in pool:      ", creditPool.isEligible(stealth));
        console.log("");

        // ── Step 2: BOOTSTRAP-SPONSORED DEPOSIT ──────────────────────────────
        console.log("--- STEP 2: Bootstrap-Sponsored CreditPool.deposit() ---");
        console.log("Simulating EntryPoint flow for stealth address...");

        // Build the UserOperation
        bytes memory depositCallData = abi.encodeCall(CreditPool.deposit, (DEMO_COMMITMENT));
        PackedUserOperation memory depositOp;
        depositOp.sender = stealth;
        depositOp.nonce = 0;
        depositOp.callData = depositCallData;
        depositOp.accountGasLimits = bytes32(abi.encodePacked(uint128(100_000), uint128(200_000)));
        depositOp.preVerificationGas = 21_000;
        depositOp.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        depositOp.paymasterAndData = abi.encodePacked(
            address(bootstrapPM),
            uint128(100_000),
            uint128(0)
        );

        // EntryPoint validates paymaster
        vm.prank(ENTRY_POINT);
        (bytes memory ctx, uint256 valData) = bootstrapPM.validatePaymasterUserOp(depositOp, bytes32(uint256(1)), 0);

        console.log("  BootstrapPaymaster validation result (0=success):", valData);
        console.log("  context length (0 = no postOp):", ctx.length);
        console.log("  stealth marked as used:", bootstrapPM.isUsed(stealth));

        // EntryPoint executes the deposit on behalf of stealth
        vm.prank(stealth);
        creditPool.deposit(DEMO_COMMITMENT);

        uint256 poolRoot = creditPool.currentRoot();
        console.log("  Commitment inserted. Pool size:", creditPool.treeSize());
        console.log("  New Merkle root (hex):", poolRoot);
        console.log("  CreditPaymaster root mirrored:", creditPM.merkleRoot() == poolRoot);
        console.log("");

        // ── Step 3: ANONYMOUS CREDIT SPEND ───────────────────────────────────
        console.log("--- STEP 3: Anonymous Credit Spend by Unrelated Spender ---");
        console.log("spender is unrelated to stealth - linkability is broken");

        bytes32 uopHash = keccak256(abi.encodePacked("demo_userop_hash"));
        uint256 uopHashUint = uint256(uopHash);

        ISemaphore.SemaphoreProof memory proof = ISemaphore.SemaphoreProof({
            merkleTreeDepth: 1,
            merkleTreeRoot: poolRoot,
            nullifier: DEMO_NULLIFIER,
            message: uopHashUint,  // bound to this exact UserOp
            scope: CREDIT_NULLIFIER_SCOPE, // credit-scoped nullifier
            points: [uint256(1), 2, 3, 4, 5, 6, 7, 8]
        });

        PackedUserOperation memory spendOp;
        spendOp.sender = spender;
        spendOp.nonce = 0;
        spendOp.callData = abi.encodeWithSignature("doSomething()");
        spendOp.accountGasLimits = bytes32(abi.encodePacked(uint128(50_000), uint128(100_000)));
        spendOp.preVerificationGas = 21_000;
        spendOp.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        bytes memory encodedProof = abi.encode(proof);
        spendOp.paymasterAndData = abi.encodePacked(
            address(creditPM),
            uint128(200_000),
            uint128(0),
            encodedProof,                  // starts at offset 52
            uint16(encodedProof.length),   // PAYMASTER_SIG_MAGIC convention
            bytes8(0x22e325a297439656)     // PAYMASTER_SIG_MAGIC: excludes proof from userOpHash
        );

        vm.prank(ENTRY_POINT);
        (, uint256 spendVal) = creditPM.validatePaymasterUserOp(spendOp, uopHash, 0);

        console.log("  CreditPaymaster validation result (0=success):", spendVal);
        console.log("  Nullifier marked spent:", creditPM.isNullifierSpent(DEMO_NULLIFIER));
        console.log("");
        console.log("=== Demo complete: stealth depositor and spender are unlinkable ===");
    }
}
