# PrivGas: Implementation Technical Report

Companion to *PrivGas: A Privacy-Preserving Gas Sponsorship Protocol for Blockchain Stealth
Addresses*. This report documents the reference implementation and uses the paper's notation
throughout; see `PAPER_SUPPLEMENT.md` for the claim-to-evidence map and `GAS_REPORT.md` for
measurement methodology.

**Notation** (as in the paper): $F$ non-refundable fee; $V_{\min}$ minimum forwarded value;
$B_{\text{boot}}$, $B_{\text{spend}}$ maximum sponsorship costs of the two paymasters;
$p_{\max}$ maximum accepted gas price; $\kappa$ economic safety margin; $C$ identity
commitment; $R$ Merkle root; $N$ nullifier; $D = \operatorname{uint256}(\textit{userOpHash})$
the sponsorship digest; $S_{\text{credit}}$ the fixed credit-spending scope.

## 1. Problem Statement

ERC-5564 stealth addresses sever the on-chain link between a sender and recipient: the sender broadcasts an ephemeral public key; only the intended recipient can derive the stealth address using their scanning key. This solves the address-reuse privacy problem but creates a bootstrapping problem — the recipient's freshly derived stealth address has no ETH and therefore cannot pay gas to interact with the network. Any naive gas-payment mechanism (ETH faucet, cross-chain bridge, exchange withdrawal) reintroduces a linkable on-chain event that defeats the privacy gain.

Under ERC-4337 the problem is not merely relaying: `UserOperation.sender` is structurally
visible to bundlers and to the paymaster, so gas sponsorship for stealth accounts is a
Sybil-resistant *admission-control* problem. PrivGas targets the paper's three goals:

* **G1 — Sybil resistance.** A usable sponsorship credit cannot be manufactured for less than
  the non-refundable cost $F$ (§3.2).
* **G2 — Gas top-up unlinkability.** No recipient-side top-up from a known wallet, and the
  paymaster does not learn which commitment was redeemed (§3.1).
* **G3 — One-credit redemption.** A deposited credit sponsors at most one later operation (§3.3).

All three are pursued while satisfying ERC-7562's rules for bundler-safe paymasters (§3.4).

---

## 2. System Architecture

The protocol comprises four contracts deployed in a directed dependency graph, with two supporting libraries that decouple business logic from the ERC-4337 interface.

```
Stage 1 (Fund)
  Sender ──► AnnouncementRegistry ──── announces ──►  ERC-5564 Announcer
                │      │                                    (0x5564…5564)
                │      └── routes F ──► non-recoverable fee sink
                │ mirrorEligible()
                ▼
Stage 2 (Bootstrap)
       BootstrapPaymaster          CreditPool ◄── mirrorEligible()
              │                        │
              │ sponsors               │ deposit(C)
              ▼                        ▼
       [stealth smart account]    CreditPaymaster ◄── mirrorRoot(R)
       execute(pool, 0,                │
               deposit(C))             │ sponsors
                                       ▼
Stage 3 (Spend)                   [any UserOperation]

```

### 2.1 AnnouncementRegistry

**Role.** Gateway that ties ERC-5564 announcements to an irrecoverable on-chain cost and propagates eligibility atomically to both paymasters.

**Core operation** — `announceAndFund(schemeId, stealthAddress, ephemeralPubKey, metadata)`:

1. Requires `msg.value` $\ge V_{\min} + F$.
2. Routes $F$ to the non-recoverable fee sink, implemented as a transfer to `address(0)` — permanently unspendable on any EVM chain; the genuine Sybil cost.
3. Forwards `msg.value` $- F$ ($\ge V_{\min}$) to `stealthAddress` — funds bootstrap gas.
4. Calls `announcer.announce(...)` on the canonical ERC-5564 Announcer.
5. Records `eligible[stealthAddress] = true` in own storage.
6. Calls `bootstrapPaymaster.mirrorEligible(stealthAddress)` and `creditPool.mirrorEligible(stealthAddress)` — atomic push to downstream contracts so no external `SLOAD` is ever needed during paymaster validation.

**Owner controls:** `setVMin(uint256)`, `setNonRefundableFee(uint256)`, `transferOwnership(address)`.

**Sybil invariant (paper Eq. 1).** The registry enforces the minimum admissible fee at deployment and on update:

$$F > \kappa \cdot (B_{\text{boot}} + B_{\text{spend}})$$

`MIN_NON_REFUNDABLE_FEE` = 0.02 ETH is an *exclusive* lower bound, so any $F \le 0.02$ ETH is rejected by both the constructor and `setNonRefundableFee`. See §3.2 for the instantiated numbers.

Only $F$ appears in the bound because only $F$ is unrecoverable: the forwarded $V_{\min}$ can be re-extracted by an attacker who controls `stealthAddress` in a self-dealing round trip, so a gate priced on recoverable value provides no Sybil cost at all.

---

### 2.2 BootstrapPaymaster

**Role.** ERC-4337 paymaster that sponsors exactly one transaction per eligible stealth address: the credit deposit into `CreditPool`. After this one use the address is marked used and cannot obtain a second free gas sponsorship through this path.

**Validation logic (`validatePaymasterUserOp`):**

1. **Sponsorship budget:** `maxCost <= MAX_BOOTSTRAP_SPONSORSHIP_COST` (0.005 ETH). `maxCost` is the EntryPoint's `requiredPrefund`, so the bound covers all five gas terms rather than a subset.
2. **Gas price:** `maxFeePerGas <= MAX_ACCEPTED_MAX_FEE_PER_GAS` (10 gwei).
3. **Eligibility and single use:** reads only own storage, `_eligible[sender]` and `_used[sender]`.
4. **Call shape:** delegates to `EligibilityLogic.checkBootstrapEligible`. Because ERC-4337 executes `callData` on `userOp.sender`, a Bootstrap operation must be an *account execution* wrapping the pool call, not the pool call itself. The library pins every field of

   ```
   execute(address(creditPool), 0, abi.encodeCall(CreditPool.deposit, (commitment)))
   ```

   namely the `execute(address,uint256,bytes)` selector, the target, a zero ETH value, the canonical bytes offset (`0x60`), the 36-byte inner length, and the inner `deposit(uint256)` selector. Only the commitment argument is free. This prevents the free gas from being redirected to any other call.
5. On success: sets `_used[sender] = true` and returns `("", 0)` (`SIG_VALIDATION_SUCCESS`).

Steps 1–2 revert with typed errors (`MaxCostExceeded`, `GasPriceCapExceeded`); steps 3–4 return `SIG_VALIDATION_FAILED`, which the EntryPoint surfaces as `FailedOp(i, "AA34 signature error")`.

**ERC-7562 compliance:** All storage reads are from this contract's own mappings (populated by `mirrorEligible`). No banned opcodes (`TIMESTAMP`, `BLOCKHASH`, `COINBASE`, `BASEFEE`, etc.) appear in the validation path. Contract is staked at the EntryPoint.

---

### 2.3 CreditPool

**Role.** Incremental Lean Merkle Tree (LeanIMT, Semaphore v4) of Semaphore identity commitments. Each leaf is a `commitment = Poseidon(EdDSA_pubkey over Baby Jubjub)` generated off-chain by the `@semaphore-protocol/identity` v4 SDK. The depositor's stealth address is not stored; only the commitment leaf is inserted.

**Key design decisions:**

* **Dual access check.** `deposit()` enforces its own `_eligible`/`_used` check independent of BootstrapPaymaster. This prevents a self-funded attacker from calling `deposit()` directly without going through the `V_MIN` cost path.
* **Mirror pattern.** After each successful insertion, `creditPaymaster.mirrorRoot(newRoot)` pushes the new Merkle root to CreditPaymaster's own storage, keeping it fresh without requiring CreditPaymaster to `SLOAD` an external contract during validation.
* **One deposit per address.** `_used[msg.sender]` is set on first successful deposit; subsequent calls revert with `AlreadyDeposited`. An identity (commitment) can only appear once per stealth address, though multiple stealth addresses can deposit different identities.

---

### 2.4 CreditPaymaster

**Role.** ERC-4337 paymaster that sponsors arbitrary transactions for any sender, authenticated by a Semaphore v4 Groth16 zero-knowledge membership proof. The proof demonstrates knowledge of a private identity that was committed in the Merkle tree without revealing which leaf or which stealth address deposited it.

**paymasterAndData layout (ERC-4337 v0.9 paymaster-signature region):**

```
[0:20]   paymaster address
[20:36]  paymasterVerificationGasLimit (uint128)
[36:52]  paymasterPostOpGasLimit (uint128)
[52:N]   abi.encode(SemaphoreProof)
[N:N+2]  uint16(proofLen)
[N+2:]   PAYMASTER_SIG_MAGIC (0x22e325a297439656, 8 bytes)

```

The `PAYMASTER_SIG_MAGIC` suffix causes `UserOperationLib.paymasterDataKeccak` to exclude the proof bytes from `userOpHash`, making the hash stable before proof generation and breaking the circular dependency $proof.message = userOpHash \rightarrow proof\ changes \rightarrow userOpHash\ changes$. The exclusion covers both the content and the length of the proof region, so a placeholder proof and the real proof hash identically — asserted directly by `test_operationHashIsIndependentOfProofBytes`.

**Validation logic (`validatePaymasterUserOp`), in order:**

1. **Sponsorship budget:** `maxCost <= MAX_SPONSORSHIP_COST` (0.005 ETH $=$ `MAX_CREDIT_GAS` $\times$ `MAX_ACCEPTED_MAX_FEE_PER_GAS`). Checked against the EntryPoint's `requiredPrefund`, not a gas-field proxy.
2. **Gas cap:** `callGasLimit` + `verificationGasLimit` $\le$ `MAX_CREDIT_GAS` (500,000 gas units).
3. **Gas price:** `maxFeePerGas` $\le$ `MAX_ACCEPTED_MAX_FEE_PER_GAS` (10 gwei).
4. **Proof extraction** via `UserOperationLib.getPaymasterSignature(paymasterAndData)`.
5. **Merkle root check:** `proof.merkleTreeRoot == _merkleRoot` (own storage).
6. **Scope check:** `proof.scope == CREDIT_NULLIFIER_SCOPE`, a *fixed* domain constant $=$ `uint256(keccak256("stealth-protocol.credit.v1"))`. The scope is deliberately constant, not per-operation — see §3.3.
7. **Message binding:** `proof.message == uint256(userOpHash)` — binds the proof to this exact `UserOperation`.
8. **Nullifier check:** `!_nullifiers[proof.nullifier]` (own storage).
9. **ZK verification:** `ISemaphoreVerifier.verifyProof(pA, pB, pC, pubSignals, depth)` — pure BN254 Groth16 pairing computation; ERC-7562 allows precompile calls. Public signals are `[root, nullifier, hash(message), hash(scope)]` where `hash(x) = keccak256(abi.encodePacked(x)) >> 8`, matching Semaphore v4.
10. **Nullifier marking:** `_nullifiers[proof.nullifier] = true`.

All failures revert with typed errors, which the EntryPoint surfaces as `FailedOpWithRevert(i, "AA33 reverted", <inner error>)`.

**ERC-7562 compliance:** Reads only `_merkleRoot` and `_nullifiers` (own storage). `verifyProof` is a pure precompile sequence. No banned opcodes.

---

### 2.5 Supporting Libraries

`EligibilityLogic` (pure): `checkBootstrapEligible(eligible, used, callData, executeSelector, creditPool, depositSelector)` and `checkDepositEligible(eligible, used)`. The first also validates the full account-execution call shape described in §2.2. Decoupled from ERC-4337 so the logic can be reused under a different transaction format (e.g. EIP-8141 native AA) without rewriting.

`NullifierLogic` (pure): `isSpent(mapping, nullifier)` and `checkAndMark(mapping, nullifier)`. Encapsulates the double-spend prevention logic independently of the paymaster interface.

---

## 3. Security Analysis

### 3.1 Privacy Properties (G2, Lemma 2)

Corresponds to **G2** and **Lemma 2** in the paper. Two distinct properties, deliberately scoped.

**No recipient-side gas top-up.** The recipient never funds the stealth account from a known
wallet in order to spend, which removes the direct funding heuristic that deanonymises a large
fraction of live ERC-5564 users.

**Commitment-index privacy.** The on-chain trace of a credit spend reveals only:

* the nullifier $N$ (an opaque field element),
* the Merkle root $R$ at proof time (public, known to all),
* the `userOp.sender` (the spender, not the depositor).

The ZK proof reveals set membership ($C \in$ tree) without revealing which leaf, so the
paymaster does not learn the redeemed commitment index. The stealth address does not appear in
the spend transaction.

**Not covered**, matching the paper's statement of Lemma 2: Bootstrap participation is public;
timing correlation between stages, network metadata, target-call behaviour, credit denomination,
and cold-start anonymity-set limits are all outside the guarantee. The evaluation group has four
members, so the artifact demonstrates the mechanism, not a deployment-scale anonymity set.

---

### 3.2 Sybil Resistance (G1, Lemma 1)

Corresponds to **G1** and **Lemma 1** in the paper.

**Attack model.** A self-dealing adversary controlling the sender, the recipient stealth address, and the target contract simultaneously attempts to acquire many $(\mathsf{stealthAddr}, \text{credit})$ pairs at negligible cost.

**Why a recoverable-value gate is insufficient.** If admission were priced on $V_{\min}$ alone — forwarded in full to `stealthAddress` — an attacker controlling that address withdraws the forwarded ETH in the same block and keeps the sponsorship credit. The realised cost per Sybil credit collapses to announcement gas, not $V_{\min}$.

**Separation of recoverable from unrecoverable value.** $F$ is routed to the non-recoverable fee sink *before* the residual is forwarded, so it cannot be recovered regardless of who controls `stealthAddress`. `test_selfDealing_roundTrip_attackerLosesNonRefundableFee` runs the full round trip and asserts the attacker's net loss equals exactly $F$: the forwarded $V_{\min}$ is fully recycled, $F$ is not. This is why Eq. (1) is stated over $F$ alone.

**Invariant.** The bound is stated over *total* sponsored exposure — both phases, not just Spend:

$$F > \kappa \times (B_{\text{boot}} + B_{\text{spend}})$$

where $B_{\text{boot}}$ and $B_{\text{spend}}$ are the maximum sponsorship costs the two paymasters accept. Both are enforced in wei against the EntryPoint's `maxCost`, so the bound is independent of gas-price volatility rather than anchored to an assumed price:

| Symbol | Value | Enforced by |
| --- | --- | --- |
| $B_{\text{boot}}$ | 0.005 ETH | `BootstrapPaymaster.MAX_BOOTSTRAP_SPONSORSHIP_COST` |
| $B_{\text{spend}}$ | 0.005 ETH | `CreditPaymaster.MAX_SPONSORSHIP_COST` |
| $p_{\max}$ | 10 gwei | `MAX_ACCEPTED_MAX_FEE_PER_GAS` (both) |
| $\kappa$ | 2 | design parameter |
| $F$ | 0.021 ETH | `AnnouncementRegistry`, configured |

$$F = 0.021\text{ ETH} \;>\; 2 \times (0.005 + 0.005) = 0.020\text{ ETH} \quad \checkmark$$

The inequality is strict with a 5% margin. `AnnouncementRegistry.MIN_NON_REFUNDABLE_FEE` (0.02 ETH, exclusive) rejects a non-conforming $F$ at both construction and update, so a configuration violating the bound cannot be installed.

**Why both phases must be bounded.** Bootstrap sponsorship is charged to the paymaster whether or not the sponsored call succeeds, and the account's verification phase is attacker-controlled code. Without a Bootstrap budget, $c_{\text{credit}}$ is unbounded and no positive $\kappa$ satisfies the inequality, regardless of the Spend-side cap.

---

### 3.3 Replay Prevention (G3, Lemma 3)

Two distinct bindings are needed, and they use two different proof fields.

**Nullifier uniqueness (one credit, one spend) — fixed scope.** `proof.scope` is a *constant* domain separator, `CREDIT_NULLIFIER_SCOPE = uint256(keccak256("stealth-protocol.credit.v1"))`. The circuit derives `nullifier = Poseidon(secret, hash(scope))`, so a given identity yields **the same nullifier on every spend attempt, forever**. The first spend records it in `_nullifiers`; any later proof from that identity reveals the identical nullifier and is rejected.

This is why the scope must not be per-operation. Were `scope = uint256(userOpHash)`, every operation would produce a *different* nullifier from the same credit, and the replay check would never fire — one credit could sponsor unlimited operations. Domain separation, not freshness, is what makes the nullifier a spend marker.

**Operation binding (no transplantation) — message.** `proof.message == uint256(userOpHash)` binds the proof to one exact `UserOperation`. Since `userOpHash` is an EIP-712 digest over all operation fields, including `sender`, nonce, callData and gas limits, a proof cannot be moved to a different operation or a different sender. The binding is enforced twice: the paymaster compares `proof.message` to the EntryPoint-supplied `userOpHash`, and `hash(message)` is a public signal of the Groth16 proof, so overwriting the struct field to defeat the equality check causes the pairing to fail instead. Both failure modes are exercised in `test_validProof_senderMismatch_rejected` and `test_validProof_differentUserOperation_rejected`.

---

### 3.4 ERC-7562 Bundler Safety

The mirror-and-stake pattern satisfies ERC-7562's storage access rules:

* `BootstrapPaymaster.validatePaymasterUserOp` reads only `this._eligible` and `this._used`.
* `CreditPaymaster.validatePaymasterUserOp` reads only `this._merkleRoot` and `this._nullifiers`.
* Both are populated in the execution phase (not validation phase) by `AnnouncementRegistry.announceAndFund` and `CreditPool.deposit`, respectively.
* The Groth16 verification (`ecMul`, `ecAdd`, `ecPairing` precompiles) is a pure computation — no storage reads or forbidden opcodes.

---

## 4. Implementation

**Language / toolchain:** Solidity 0.8.28, via-IR enabled, optimizer 200 runs, Foundry `1.4.1-stable`.

**External dependencies** (vendored; versions and subtree checksums in `DEPENDENCIES.md`):

* `eth-infinitism/account-abstraction` v0.9 (pre-release snapshot) — `IPaymaster`, `PackedUserOperation`, `UserOperationLib`, `EntryPoint`, `EntryPointSimulations`, `SimpleAccount`. Note the v0.9 EIP-712 `userOpHash` domain and the `PAYMASTER_SIG_MAGIC` paymaster-signature region, which §2.4 depends on and which earlier EntryPoint versions do not provide.
* `semaphore-protocol/semaphore` v4 — `LeanIncrementalMerkleTree` (LeanIMT), `SemaphoreVerifier` (BN254 Groth16), `ISemaphore.SemaphoreProof`
* `OpenZeppelin/openzeppelin-contracts` — `MessageHashUtils` (EIP-712 hashing, used by EntryPoint)

**Code size:**

| Contract | Lines |
| --- | --- |
| AnnouncementRegistry | 145 |
| BootstrapPaymaster | 163 |
| CreditPool | 104 |
| CreditPaymaster | 219 |
| EligibilityLogic | 63 |
| NullifierLogic | 23 |
| AcceptAllPaymaster (gas baseline only) | 32 |
| **Total (production)** | **749** |
| Test suite | 2,615 |

Circular constructor dependency (`CreditPaymaster` needs `CreditPool` address; `CreditPool` needs `CreditPaymaster` address) is resolved deterministically using `vm.computeCreateAddress(deployer, nonce + k)` to pre-compute all addresses before any deployment.

---

## 5. Evaluation

### 5.1 Gas Costs (Measured, Foundry EVM)

Maxima from `forge test --gas-report` over the complete 65-test suite. These are measured with the **real** `SemaphoreVerifier`, not derived from a mock baseline.

| Operation | Gas (max) | Notes |
| --- | --- | --- |
| `announceAndFund()` | **175,951** | announce emit + 2 CALL (fee to sink + forward) + 2 `mirrorEligible` SSTOREs. Foundry EVM charges NEWACCOUNT (25,000) for the first ETH send to `address(0)`; on mainnet this does not apply, as `address(0)` already holds balance |
| `CreditPool.deposit()` | **216,905** | LeanIMT insertion into a populated tree + Poseidon hashing + `mirrorRoot` SSTORE |
| `BootstrapPaymaster.validatePaymasterUserOp()` | **52,543** | budget + gas-price checks, six calldata call-shape checks, 2 SLOAD, 1 SSTORE (`_used`) |
| `CreditPaymaster.validatePaymasterUserOp()` | **284,527** | full accept path including real BN254 Groth16 verification |

Whole-operation costs through `EntryPoint.handleOps` (EntryPoint-accounted `actualGasUsed`): **354,745** for Spend, **223,579** for Bootstrap. `GAS_REPORT.md` gives per-frame breakdowns, full min/avg/median/max distributions, and the measurement-population caveat for the two figures that depend on which suites are in the run.

---

### 5.2 Groth16 Verification Gas (Measured, Real BN254)

BN254 Groth16 proof verification (Semaphore v4) was measured using valid BN254 curve points (G1/G2 generators) as a dummy proof through the real `SemaphoreVerifier.sol`, not the mock. All precompile calls execute fully (`ecMul` $\times$ 4, `ecAdd` $\times$ 4, `ecPairing` $\times$ 1 with 3 pairs = 768 bytes). The proof is cryptographically invalid, but gas cost is identical to a valid proof because the EVM runs the pairing unconditionally.

| Tree depth | Gas measured |
| --- | --- |
| 1 (minimum) | **225,733** |
| 16 (production) | **225,732** |

The 1-gas difference confirms pairing cost is depth-independent. The 4 VK IC multiplications (`ecMul`, 6,000 gas each) are constant across depths; only the VK point coordinates differ. The dominant cost is `ecPairing` with 3 pairs: approximately 34,000 + 45,000 $\times$ 3 = 169,000 gas (EIP-1108).

---

### 5.3 ERC-4337 simulateValidation (EntryPointSimulations)

Both paymasters were validated against the full ERC-4337 validation dispatch using `EntryPointSimulations.simulateValidation` on a local Foundry EVM. Note this is a *preliminary* scope check: it confirms both paymasters pass the real dispatch reading only their own storage and that both are staked, but it performs no opcode tracing. Forbidden-opcode compliance is argued by code review, not verified mechanically. The six functional-correctness cases and the Bootstrap cases additionally run through the real `EntryPoint.handleOps`.

| Paymaster | preOpGas | paymasterValidationData | Staked |
| --- | --- | --- | --- |
| BootstrapPaymaster | 80,819 | 0 (SUCCESS) | 0.5 ETH |
| CreditPaymaster | 93,902 | 0 (SUCCESS) | 0.5 ETH |

`paymasterValidationData = 0 = SIG_VALIDATION_SUCCESS` (no time range, no aggregator). Both paymasters pass the real EntryPoint dispatch without reverting under any scenario tested.

**Engineering note on CreditPaymaster.** A naive design stores the Semaphore proof at `paymasterAndData[52:]`, which includes the proof bytes in `paymasterDataKeccak` $\rightarrow$ `userOpHash`. Since `proof.message` must equal $D = \operatorname{uint256}(\textit{userOpHash})$, that creates a circular dependency with no pre-computable solution. The fix adopts the ERC-4337 `PAYMASTER_SIG_MAGIC` convention (`0x22e325a297439656`): appending `uint16(proofLen)` $\mid\mid$ `magic` to `paymasterAndData` instructs `paymasterDataKeccak` to exclude proof bytes from the hash. `userOpHash` is then stable before proof generation, breaking the cycle. The stable hash is confirmed by asserting `getUserOpHash(op_placeholder) == getUserOpHash(op_real_proof)` in the test.

**Implementation subtlety:** `EntryPointSimulations.__domainSeparatorV4` is stored in a regular storage slot (not an immutable) and is initialized lazily inside `_simulationOnlyValidations()`. Calling `getUserOpHash()` before any `simulateValidation` returns a hash with domain separator = 0, mismatching what the internal validation computes. The test works around this by running one successful bootstrap `simulateValidation` in `setUp()` to initialize the slot before any `getUserOpHash()` calls are made.

---

### 5.4 Test Coverage

| Test file | Tests | What is verified |
| --- | --- | --- |
| FunctionalCorrectness.t.sol | 7 | The six paper correctness cases through real `handleOps`, real verifier, genuine Groth16 proofs, plus operation-hash stability |
| BootstrapSponsorshipBound.t.sol | 7 | End-to-end sponsored deposit; budget and gas-price caps; three call-shape rejections |
| CreditPaymaster.t.sol | 12 | Valid proof, bad root, spent nullifier, gas cap, scope/message checks (mock verifier unit tests) |
| AnnouncementRegistry.t.sol | 8 | Happy path, sub-minimum rejection, fee/vMin updates |
| BootstrapPaymaster.t.sol | 8 | Eligibility, already-used rejection, wrong callData |
| CreditPool.t.sol | 6 | Leaf insertion, root update, double-deposit rejection |
| SybilResistance.t.sol | 6 | Self-dealing round trip, sub-minimum boundary, eligibility |
| ReplayResistance.t.sol | 4 | Same nullifier rejected, different nullifiers both accepted |
| RealGroth16.t.sol | 2 | Real BN254 Groth16 gas measurement at depth 1 and 16 |
| SimulateValidation.t.sol | 2 | Full ERC-4337 validation dispatch for both paymasters |
| Integration.t.sol | 1 | Three-stage flow: announce $\rightarrow$ bootstrap $\rightarrow$ anonymous spend |
| PaymasterGasBaseline.t.sol | 1 | Validation gas versus an unconditional paymaster |
| RealSemaphoreCreditPaymaster.t.sol | 1 | Real fixture proof accepted; reuse rejected |
| **Total** | **65** | **All pass** |

The suites divide into two kinds. `FunctionalCorrectness` and `BootstrapSponsorshipBound` are full ERC-4337 integration tests using the real EntryPoint, a real `SimpleAccount` sender, and the real Semaphore verifier; these back the paper's claims. The remaining suites are unit tests that call `validatePaymasterUserOp` directly and may use `MockSemaphoreVerifier` to isolate control flow — they are not used to substantiate any reported result.

---

## 6. Protocol Flow Summary

### Stage 1 — FUND (on-chain, linkable)

* Sender calls: `AnnouncementRegistry.announceAndFund{value: V_min + F}(stealthAddr, ...)`
* $\rightarrow$ $F$ routed to the non-recoverable fee sink `[Sybil cost: irrecoverable]`
* $\rightarrow$ $V_{\min}$ forwarded to `stealthAddr` `[gas seed]`
* $\rightarrow$ ERC-5564 Announcement emitted `[recipient can scan and derive key]`
* $\rightarrow$ eligibility mirrored atomically `[bootstrapPM._eligible, creditPool._eligible]`



### Stage 2 — BOOTSTRAP (ERC-4337, gas-free for the stealth account)

* Stealth smart account submits UserOp:
  `callData = execute(creditPool, 0, deposit(C))`
  — ERC-4337 executes `callData` *on the sender*, so the pool call must be wrapped in an account execution
* Bundler validates via BootstrapPaymaster:
* $\rightarrow$ checks `maxCost` $\le B_{\text{boot}}$ and `maxFeePerGas` $\le p_{\max}$
* $\rightarrow$ checks `_eligible[sender]`, `!_used[sender]` (own storage)
* $\rightarrow$ pins the call shape: execute selector, target $=$ pool, value $=0$, inner `deposit(uint256)`
* $\rightarrow$ marks `_used[sender] = true`
* $\rightarrow$ returns `SIG_VALIDATION_SUCCESS`


* EntryPoint executes `callData`:
* $\rightarrow$ `SimpleAccount.execute` $\rightarrow$ `CreditPool.deposit(C)` inserts leaf $C$ into the LeanIMT
* $\rightarrow$ new root $R$ pushed to `CreditPaymaster._merkleRoot`
* `[stealth account pays zero gas]`



### Stage 3 — SPEND (ERC-4337, redeemed anonymously)

* Any address submits UserOp with `paymasterAndData = [..., SemaphoreProof, len, MAGIC]`
* Bundler validates via CreditPaymaster:
* $\rightarrow$ checks `maxCost` $\le B_{\text{spend}}$, gas cap, and `maxFeePerGas` $\le p_{\max}$
* $\rightarrow$ checks $R$ matches `_merkleRoot` (own storage)
* $\rightarrow$ checks `proof.scope` $= S_{\text{credit}}$ (fixed domain, so the nullifier is a stable spend marker)
* $\rightarrow$ checks `proof.message` $= D = \operatorname{uint256}(\textit{userOpHash})$ (binds the proof to this op and its sender)
* $\rightarrow$ checks `_nullifiers[N] == false` (own storage)
* $\rightarrow$ runs `SemaphoreVerifier.verifyProof` (BN254 Groth16, 225,733 gas isolated)
* $\rightarrow$ marks $N$ spent
* $\rightarrow$ returns `SIG_VALIDATION_SUCCESS`


* `[sender ≠ depositor; the paymaster does not learn which leaf was redeemed]`

---

## 7. Limitations and Future Work

* **One credit per stealth address.** `CreditPool.deposit` allows exactly one insertion per eligible address. An address that has deposited cannot deposit again, even with a fresh identity commitment. Lifting this restriction requires removing the `_used` check in `deposit()`, which weakens the Sybil bound.
* **Scanning cost.** Recipients must scan ERC-5564 announcements to discover funds. At high announcement volume this is computationally expensive. Stealth address meta-address registries (ERC-6538) can reduce the scan set.
* **V_MIN utility.** The forwarded `vMin` funds bootstrap gas. After `BootstrapPaymaster` sponsors the deposit, the remaining `vMin` balance on the stealth address is small and serves no further protocol purpose. It is spendable as normal ETH.
* **Gas cap conservatism.** `MAX_CREDIT_GAS` = 500,000 was set conservatively. With real Groth16 verification costing 225,733 gas, a credit-sponsored transaction has a remaining budget of ~274,267 gas for the call itself — sufficient for most DeFi operations but not complex multi-step calls.
* **Paymaster signature convention.** Carrying the proof in the `PAYMASTER_SIG_MAGIC` region (§5.3) requires off-chain clients (bundlers, wallets, proof generators) to adopt that encoding. A version byte at offset 52 could ease migration.
* **Single mirrored root.** `CreditPaymaster` accepts only the latest root pushed by `CreditPool`; there is no root history or validity window. A deposit that lands between proof generation and inclusion invalidates the outstanding proof, which must then be regenerated against the new root. This is a liveness cost, not a soundness one, and is disclosed in the paper.
* **Stealth-account derivation not implemented.** The paper models the stealth account as a counterfactual CREATE2 account deployed from a canonical factory via `initCode` on first use. The artifact uses a directly deployed `SimpleAccount` as the ERC-4337 sender and implements neither ERC-5564 key derivation nor the factory `initCode` path; every fixture operation carries `initCode = ""`.
* **Preliminary ERC-7562 checking.** Validation-scope compliance is checked with `simulateValidation` and by code review, not by bundler-level opcode tracing (§5.3).
* **Anonymity set.** The evaluation group has four members. Cold-start exposure and timing correlation between Bootstrap and Spend are outside the cryptographic guarantee and are named as future work in the paper.