// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, stdJson} from "forge-std/Test.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockAnnouncer} from "./mock/MockAnnouncer.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {SemaphoreVerifier} from "@semaphore-protocol/contracts/base/SemaphoreVerifier.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract RealSemaphoreCreditPaymasterTest is Test {
    using stdJson for string;

    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    bytes8 internal constant PAYMASTER_SIG_MAGIC = bytes8(0x22e325a297439656);
    uint256 internal constant V_MIN = 0.01 ether;
    uint256 internal constant NONREFUNDABLE_FEE = 0.01 ether;
    uint256 internal constant SCHEME_ID = 1;

    MockAnnouncer internal announcer;
    SemaphoreVerifier internal verifier;
    AnnouncementRegistry internal registry;
    BootstrapPaymaster internal bootstrapPM;
    CreditPool internal creditPool;
    CreditPaymaster internal creditPM;

    address internal deployer = makeAddr("deployer");
    address internal sender = makeAddr("sender");
    address internal stealth = makeAddr("stealth");
    address internal spender = makeAddr("spender");

    function setUp() public {
        vm.deal(deployer, 100 ether);
        vm.deal(sender, 100 ether);
        vm.deal(stealth, 1 ether);
        vm.deal(spender, 10 ether);

        vm.startPrank(deployer);
        announcer = new MockAnnouncer();
        verifier = new SemaphoreVerifier();

        uint64 nonce = vm.getNonce(deployer);
        address creditPMAddr = vm.computeCreateAddress(deployer, nonce);
        address creditPoolAddr = vm.computeCreateAddress(deployer, nonce + 1);
        address bootstrapPMAddr = vm.computeCreateAddress(deployer, nonce + 2);
        address registryAddr = vm.computeCreateAddress(deployer, nonce + 3);

        creditPM = new CreditPaymaster(ENTRY_POINT, creditPoolAddr, address(verifier));
        creditPool = new CreditPool(creditPMAddr, registryAddr);
        bootstrapPM = new BootstrapPaymaster(ENTRY_POINT, registryAddr, CreditPool.deposit.selector);
        registry = new AnnouncementRegistry(
            address(announcer),
            bootstrapPMAddr,
            creditPoolAddr,
            V_MIN,
            NONREFUNDABLE_FEE
        );
        vm.stopPrank();
    }

    function test_realSemaphoreProof_creditPaymasterSpendAndReuseRejected() public {
        ISemaphore.SemaphoreProof memory proof = _loadProof();
        bytes32 userOpHash = bytes32(proof.message);

        vm.prank(sender);
        registry.announceAndFund{value: V_MIN + NONREFUNDABLE_FEE}(
            SCHEME_ID,
            stealth,
            bytes("pk"),
            bytes("")
        );

        vm.prank(stealth);
        creditPool.deposit(proof.merkleTreeRoot);

        assertEq(creditPool.currentRoot(), proof.merkleTreeRoot, "fixture root mismatch");
        assertEq(creditPM.merkleRoot(), proof.merkleTreeRoot, "mirrored root mismatch");

        PackedUserOperation memory userOp = _buildCreditUserOp(proof);

        vm.prank(ENTRY_POINT);
        (, uint256 validationData) = creditPM.validatePaymasterUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0, "real proof validation failed");
        assertTrue(creditPM.isNullifierSpent(proof.nullifier), "nullifier not spent");

        ISemaphore.SemaphoreProof memory secondProof = proof;
        secondProof.message = uint256(bytes32(uint256(0x987654321)));
        PackedUserOperation memory secondOp = _buildCreditUserOp(secondProof);

        vm.prank(ENTRY_POINT);
        vm.expectRevert(
            abi.encodeWithSelector(CreditPaymaster.NullifierSpent.selector, proof.nullifier)
        );
        creditPM.validatePaymasterUserOp(secondOp, bytes32(secondProof.message), 0);
    }

    function _buildCreditUserOp(ISemaphore.SemaphoreProof memory proof)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = spender;
        userOp.nonce = 0;
        userOp.callData = abi.encodeWithSignature("doSomething()");
        userOp.accountGasLimits = bytes32(abi.encodePacked(uint128(250_000), uint128(100_000)));
        userOp.preVerificationGas = 21_000;
        userOp.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));

        bytes memory proofEncoded = abi.encode(proof);
        userOp.paymasterAndData = abi.encodePacked(
            address(creditPM),
            uint128(300_000),
            uint128(0),
            proofEncoded,
            uint16(proofEncoded.length),
            PAYMASTER_SIG_MAGIC
        );
    }

    function _loadProof() internal view returns (ISemaphore.SemaphoreProof memory proof) {
        string memory json = vm.readFile("test/fixtures/semaphore-valid-proof-depth1.json");
        proof.merkleTreeDepth = json.readUint(".proof.merkleTreeDepth");
        proof.merkleTreeRoot = json.readUint(".proof.merkleTreeRoot");
        proof.nullifier = json.readUint(".proof.nullifier");
        proof.message = json.readUint(".proof.message");
        proof.scope = json.readUint(".proof.scope");

        for (uint256 i = 0; i < 8; i++) {
            proof.points[i] = json.readUint(string.concat(".proof.points[", vm.toString(i), "]"));
        }
    }
}
