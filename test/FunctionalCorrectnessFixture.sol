// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {SimpleAccount} from "account-abstraction/accounts/SimpleAccount.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ISemaphore} from "@semaphore-protocol/contracts/interfaces/ISemaphore.sol";
import {SemaphoreVerifier} from "@semaphore-protocol/contracts/base/SemaphoreVerifier.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {BootstrapPaymaster} from "../src/BootstrapPaymaster.sol";
import {CreditPaymaster} from "../src/CreditPaymaster.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockAnnouncer} from "./mock/MockAnnouncer.sol";

/// @notice Trivial call target so the accepted operation performs an observable action.
contract SponsoredTarget {
    uint256 public counter;

    function ping() external {
        counter += 1;
    }
}

/// @title FunctionalCorrectnessFixture
/// @notice Deterministic deployment and UserOperation construction shared verbatim by
///         `script/proof/DumpUserOpHashes.s.sol` (which emits the operation hashes the
///         Groth16 proofs are generated over) and `test/FunctionalCorrectness.t.sol`
///         (which replays the identical deployment and submits those proofs).
///
///         Both consumers inherit this contract, so the deployment sequence cannot drift
///         between the two phases. Every contract is created by DEPLOYER under a prank, so
///         all addresses are a pure function of (DEPLOYER, nonce) and reproduce in either
///         context. The test additionally asserts, for every proof it submits, that
///         `entryPoint.getUserOpHash(op) == proof.message` — if an address, the chain id or
///         any operation field ever drifts, the tests fail loudly rather than silently
///         degrading into a check against an arbitrary literal.
///
///         Hash stability: `paymasterAndData` carries the Groth16 proof in the ERC-4337 v0.9
///         paymaster-signature region (terminated by PAYMASTER_SIG_MAGIC). `paymasterDataKeccak`
///         excludes that region from the userOpHash entirely, so the hash is independent of
///         both the content and the length of the proof. That is what makes "generate a proof
///         over the operation's own hash" possible; it is asserted directly in
///         `test_operationHashIsIndependentOfProofBytes`.
abstract contract FunctionalCorrectnessFixture is CommonBase {
    // ── Fixed identities (hard-coded rather than derived, so the script and the test
    //    agree without depending on any forge-std helper that differs between them) ──
    address internal constant DEPLOYER = address(uint160(uint256(keccak256("privgas.fc.deployer"))));
    address internal constant FUNDER = address(uint160(uint256(keccak256("privgas.fc.funder"))));
    address internal constant BUNDLER = address(uint160(uint256(keccak256("privgas.fc.bundler"))));
    uint256 internal constant OWNER_A_KEY = 0xA11CE;
    uint256 internal constant OWNER_B_KEY = 0xB0B;

    // ── Fixed protocol parameters ────────────────────────────────────────────
    uint256 internal constant V_MIN = 0.01 ether;
    uint256 internal constant NONREFUNDABLE_FEE = 0.01 ether;
    uint256 internal constant SCHEME_ID = 1;
    uint256 internal constant CREDIT_NULLIFIER_SCOPE = uint256(keccak256("stealth-protocol.credit.v1"));

    bytes8 internal constant PAYMASTER_SIG_MAGIC = bytes8(0x22e325a297439656);

    /// Pinned so the EIP-712 domain separator (and therefore every userOpHash) is fixed.
    uint256 internal constant FIXTURE_CHAIN_ID = 31337;

    /// Credits in the pool. A 4-leaf LeanIMT yields merkleTreeDepth == 2, so the accepted
    /// proof is not a degenerate one-member (anonymity-set-of-1) group.
    uint256 internal constant GROUP_SIZE = 4;

    // ── Gas parameters shared by every fixture operation ─────────────────────
    uint128 internal constant VERIFICATION_GAS_LIMIT = 200_000;
    uint128 internal constant CALL_GAS_LIMIT = 100_000;
    uint256 internal constant PRE_VERIFICATION_GAS = 21_000;
    uint128 internal constant MAX_PRIORITY_FEE_PER_GAS = 1 gwei;
    uint128 internal constant MAX_FEE_PER_GAS = 1 gwei;
    uint128 internal constant PM_VERIFICATION_GAS_LIMIT = 400_000;
    uint128 internal constant PM_POSTOP_GAS_LIMIT = 0;

    /// Oversized paymasterVerificationGasLimit used only by the budget-overrun operation.
    /// Chosen so requiredPrefund exceeds MAX_SPONSORSHIP_COST (5e15 wei) while
    /// callGasLimit + verificationGasLimit stays under MAX_CREDIT_GAS (500 000) — i.e. the
    /// operation is rejected by the new maxCost check and by nothing else.
    uint128 internal constant OVER_BUDGET_PM_VERIFICATION_GAS_LIMIT = 5_000_000;

    // ── Deployed contracts ───────────────────────────────────────────────────
    EntryPoint internal entryPoint;
    SemaphoreVerifier internal verifier;
    MockAnnouncer internal announcer;
    CreditPaymaster internal creditPM;
    CreditPool internal creditPool;
    BootstrapPaymaster internal bootstrapPM;
    AnnouncementRegistry internal registry;
    SimpleAccount internal accountA;
    SimpleAccount internal accountB;
    SponsoredTarget internal target;

    address internal ownerA;
    address internal ownerB;

    /// @dev Deploys the full protocol at deterministic addresses. Must produce identical
    ///      addresses in the dumping script and in the test suite.
    function _deployAll() internal {
        vm.chainId(FIXTURE_CHAIN_ID);

        ownerA = vm.addr(OWNER_A_KEY);
        ownerB = vm.addr(OWNER_B_KEY);

        vm.startPrank(DEPLOYER);

        uint64 nonce = vm.getNonce(DEPLOYER);
        address creditPMAddr = vm.computeCreateAddress(DEPLOYER, nonce + 3);
        address creditPoolAddr = vm.computeCreateAddress(DEPLOYER, nonce + 4);
        address registryAddr = vm.computeCreateAddress(DEPLOYER, nonce + 6);

        entryPoint = new EntryPoint(); //                                    nonce + 0
        verifier = new SemaphoreVerifier(); //                               nonce + 1
        announcer = new MockAnnouncer(); //                                  nonce + 2
        creditPM = new CreditPaymaster( //                                   nonce + 3
            address(entryPoint), creditPoolAddr, address(verifier)
        );
        creditPool = new CreditPool(creditPMAddr, registryAddr); //          nonce + 4
        bootstrapPM = new BootstrapPaymaster( //                             nonce + 5
            address(entryPoint), registryAddr, CreditPool.deposit.selector
        );
        registry = new AnnouncementRegistry( //                              nonce + 6
            address(announcer), address(bootstrapPM), creditPoolAddr, V_MIN, NONREFUNDABLE_FEE
        );

        // SimpleAccount disables initializers in its constructor, so the accounts are
        // ERC1967 proxies over a shared implementation — exactly what SimpleAccountFactory
        // produces, without the factory's SenderCreator-only access path.
        SimpleAccount impl = new SimpleAccount(IEntryPoint(address(entryPoint))); // nonce + 7
        accountA = SimpleAccount( //                                         nonce + 8
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SimpleAccount.initialize, (ownerA)))))
        );
        accountB = SimpleAccount( //                                         nonce + 9
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SimpleAccount.initialize, (ownerB)))))
        );
        target = new SponsoredTarget(); //                                   nonce + 10

        vm.stopPrank();

        require(address(creditPM) == creditPMAddr, "fixture: creditPM address drift");
        require(address(creditPool) == creditPoolAddr, "fixture: creditPool address drift");
        require(address(registry) == registryAddr, "fixture: registry address drift");
    }

    /// @dev The four stealth depositors, in the order their commitments enter the LeanIMT.
    ///      The JS group is built in the same order, so the on-chain root and the proof's
    ///      merkleTreeRoot must agree — asserted in the test.
    function _depositor(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("privgas.fc.depositor", i)))));
    }

    // ── UserOperation builders ───────────────────────────────────────────────
    // Each returns an operation carrying a zero-filled placeholder proof of the correct ABI
    // shape. Because the proof sits in the paymaster-signature region it is excluded from the
    // userOpHash, so the placeholder and the real proof hash identically.

    function _emptyProof() internal pure returns (ISemaphore.SemaphoreProof memory p) {
        return p;
    }

    function _paymasterAndData(uint128 pmVerificationGasLimit, ISemaphore.SemaphoreProof memory proof)
        internal
        view
        returns (bytes memory)
    {
        bytes memory proofEncoded = abi.encode(proof);
        return abi.encodePacked(
            address(creditPM),
            pmVerificationGasLimit,
            PM_POSTOP_GAS_LIMIT,
            proofEncoded,
            uint16(proofEncoded.length),
            PAYMASTER_SIG_MAGIC
        );
    }

    function _baseOp(address sender, uint256 nonce, bytes memory callData, uint128 pmVerificationGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = nonce;
        op.initCode = "";
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT));
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32(abi.encodePacked(MAX_PRIORITY_FEE_PER_GAS, MAX_FEE_PER_GAS));
        op.paymasterAndData = _paymasterAndData(pmVerificationGasLimit, _emptyProof());
        op.signature = "";
    }

    /// @dev Each operation uses a distinct ERC-4337 nonce *key* (nonce = key << 64), so any
    ///      of them is valid as the first operation of its own key. This lets a test submit
    ///      operation B without having first executed operation A.
    function _nonceKey(uint192 key) internal pure returns (uint256) {
        return uint256(key) << 64;
    }

    function _pingCallData() internal view returns (bytes memory) {
        return abi.encodeCall(BaseAccount.execute, (address(target), 0,abi.encodeCall(SponsoredTarget.ping, ())));
    }

    /// The accepted operation.
    function opAccept() public view returns (PackedUserOperation memory) {
        return _baseOp(address(accountA), _nonceKey(0), _pingCallData(), PM_VERIFICATION_GAS_LIMIT);
    }

    /// A second, distinct operation from the same sender. Used both as the second spend in
    /// the spent-nullifier case and as the "different operation" target for opAccept's proof.
    function opSecond() public view returns (PackedUserOperation memory) {
        return _baseOp(
            address(accountA),
            _nonceKey(1),
            abi.encodeCall(BaseAccount.execute, (address(target), 0,"")),
            PM_VERIFICATION_GAS_LIMIT
        );
    }

    /// Identical to opAccept except for the sender. Used as the "different sender" target.
    function opOtherSender() public view returns (PackedUserOperation memory) {
        return _baseOp(address(accountB), _nonceKey(0), _pingCallData(), PM_VERIFICATION_GAS_LIMIT);
    }

    /// Requests a prefund above MAX_SPONSORSHIP_COST via paymasterVerificationGasLimit.
    function opOverBudget() public view returns (PackedUserOperation memory) {
        return _baseOp(address(accountA), _nonceKey(2), _pingCallData(), OVER_BUDGET_PM_VERIFICATION_GAS_LIMIT);
    }
}
