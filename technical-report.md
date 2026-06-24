# Stealth Protocol: Technical Report for Paper Submission

## 1. Problem Statement

ERC-5564 stealth addresses sever the on-chain link between a sender and recipient: the sender broadcasts an ephemeral public key; only the intended recipient can derive the stealth address using their scanning key. This solves the address-reuse privacy problem but creates a bootstrapping problem — the recipient's freshly derived stealth address has no ETH and therefore cannot pay gas to interact with the network. Any naive gas-payment mechanism (ETH faucet, cross-chain bridge, exchange withdrawal) reintroduces a linkable on-chain event that defeats the privacy gain.

The protocol presented here solves this bootstrapping problem without creating a new link, and extends the solution to allow fully anonymous gas sponsorship for arbitrary subsequent transactions — all while satisfying ERC-7562's rules for bundler-safe paymasters.

---

## 2. System Architecture

The protocol comprises four contracts deployed in a directed dependency graph, with two supporting libraries that decouple business logic from the ERC-4337 interface.

```
Sender ──► AnnouncementRegistry ──── announces ──►  ERC-5564 Announcer
                │                                         (0x5564…5564)
                │ mirrorEligible()
                ▼
       BootstrapPaymaster          CreditPool ◄── mirrorEligible()
              │                        │
              │ sponsors               │ deposit()
              ▼                        ▼
       [stealth address]          CreditPaymaster ◄── mirrorRoot()
       calls deposit()                 │
                                       │ sponsors
                                       ▼
                                  [any spender]

```

### 2.1 AnnouncementRegistry

**Role.** Gateway that ties ERC-5564 announcements to an irrecoverable on-chain cost and propagates eligibility atomically to both paymasters.

**Core operation** — `announceAndFund(schemeId, stealthAddress, ephemeralPubKey, metadata)`:

1. Requires `msg.value` $\ge$ `vMin` + `nonRefundableFee`.
2. Sends `nonRefundableFee` to `address(0)` — permanently unspendable on any EVM chain; the genuine Sybil cost.
3. Forwards `msg.value` $-$ `nonRefundableFee` ($\ge$ `vMin`) to `stealthAddress` — funds bootstrap gas.
4. Calls `announcer.announce(...)` on the canonical ERC-5564 Announcer.
5. Records `eligible[stealthAddress] = true` in own storage.
6. Calls `bootstrapPaymaster.mirrorEligible(stealthAddress)` and `creditPool.mirrorEligible(stealthAddress)` — atomic push to downstream contracts so no external `SLOAD` is ever needed during paymaster validation.

**Owner controls:** `setVMin(uint256)`, `setNonRefundableFee(uint256)`, `transferOwnership(address)`.

**Sybil invariant:** `nonRefundableFee` $> \kappa \times$ `c_credit` where `c_credit` = `MAX_CREDIT_GAS` gas units at the anchor gas price and $\kappa > 1$ is a safety margin. The old form `vMin` $> c_{ann} + \kappa \times$ `c_credit` was broken because `vMin` was fully recoverable via a self-dealing round trip (attacker controls `stealthAddress`, re-extracts `vMin`). The `nonRefundableFee` burn is not recoverable regardless of who controls `stealthAddress`.

---

### 2.2 BootstrapPaymaster

**Role.** ERC-4337 v0.7 paymaster that sponsors exactly one transaction per eligible stealth address: the `CreditPool.deposit(commitment)` call. After this one use the address is marked used and cannot obtain a second free gas sponsorship through this path.

**Validation logic (`validatePaymasterUserOp`):**

* Reads only own storage: `_eligible[sender]` and `_used[sender]`.
* Delegates the combined check to `EligibilityLogic.checkBootstrapEligible`, which also enforces that `callData` encodes exactly `deposit(uint256)` (4-byte selector + 32-byte argument, total 36 bytes) — preventing the free gas from being redirected to any other call.
* On success: sets `_used[sender] = true` and returns `("", 0)` (`SIG_VALIDATION_SUCCESS`).

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

**Role.** ERC-4337 v0.7 paymaster that sponsors arbitrary transactions for any sender, authenticated by a Semaphore v4 Groth16 zero-knowledge membership proof. The proof demonstrates knowledge of a private identity that was committed in the Merkle tree without revealing which leaf or which stealth address deposited it.

**paymasterAndData layout (ERC-4337 v0.7, post-v1.1 fix):**

```
[0:20]   paymaster address
[20:36]  paymasterVerificationGasLimit (uint128)
[36:52]  paymasterPostOpGasLimit (uint128)
[52:N]   abi.encode(SemaphoreProof)
[N:N+2]  uint16(proofLen)
[N+2:]   PAYMASTER_SIG_MAGIC (0x22e325a297439656, 8 bytes)

```

The `PAYMASTER_SIG_MAGIC` suffix causes `UserOperationLib.paymasterDataKeccak` to exclude the proof bytes from `userOpHash`, making the hash stable before proof generation and breaking the circular dependency $proof.scope = userOpHash \rightarrow proof\ changes \rightarrow userOpHash\ changes$.

**Validation logic (`validatePaymasterUserOp`):**

1. **Gas cap enforcement:** `callGasLimit` + `verificationGasLimit` $\le$ `MAX_CREDIT_GAS` (currently 500,000 gas units).
2. **Proof extraction** via `UserOperationLib.getPaymasterSignature(paymasterAndData)`.
3. **Merkle root check:** `proof.merkleTreeRoot == _merkleRoot` (own storage).
4. **Scope binding:** `proof.scope == uint256(userOpHash)` — binds the proof to this exact `UserOperation`.
5. **Message binding:** `proof.message == uint256(userOpHash)` — dual binding per Semaphore v4 convention.
6. **Nullifier check:** `!_nullifiers[proof.nullifier]` (own storage).
7. **ZK verification:** `ISemaphoreVerifier.verifyProof(pA, pB, pC, pubSignals, depth)` — pure BN254 Groth16 pairing computation; ERC-7562 allows precompile calls.
8. **Nullifier marking:** `_nullifiers[proof.nullifier] = true`.

**ERC-7562 compliance:** Reads only `_merkleRoot` and `_nullifiers` (own storage). `verifyProof` is a pure precompile sequence. No banned opcodes.

---

### 2.5 Supporting Libraries

`EligibilityLogic` (pure): `checkBootstrapEligible(eligible, used, callData, selector)` and `checkDepositEligible(eligible, used)`. Decoupled from ERC-4337 so the logic can be reused under a different transaction format (e.g. EIP-8141 native AA) without rewriting.

`NullifierLogic` (pure): `isSpent(mapping, nullifier)` and `checkAndMark(mapping, nullifier)`. Encapsulates the double-spend prevention logic independently of the paymaster interface.

---

## 3. Security Analysis

### 3.1 Privacy Properties

The protocol achieves unlinkability between the credit-earning address (stealth depositor) and the credit-spending address (`userOp.sender` in `CreditPaymaster`). The on-chain trace of a credit spend reveals:

* A nullifier (opaque 32-byte value)
* The Merkle root at proof time (public, known to all)
* The `userOp.sender` (the spender, not the depositor)

The ZK proof reveals only set membership ($commitment \in tree$), not which leaf or which stealth address corresponds to that commitment. The stealth address itself never appears in the spend transaction.

---

### 3.2 Sybil Resistance

**Attack model.** An adversary attempts to acquire multiple `(stealthAddress, credit)` pairs at negligible cost to gain disproportionate gas sponsorship.

**Old design flaw.** When `announceAndFund` forwarded 100% of `msg.value` to `stealthAddress` and the attacker controlled `stealthAddress`, the attacker could:

1. Call `announceAndFund{value: V_MIN}(stealthAddress = attackerControlled)`.
2. Withdraw `V_MIN` from `attackerControlled` back to themselves.
3. Repeat.

Real cost per Sybil credit: `c_ann` (gas only, ~0.001 ETH at 20 gwei). Not `V_MIN`.

**Fix.** The `nonRefundableFee` is burned to `address(0)` before forwarding. The self-dealing round-trip test (`test_selfDealing_roundTrip_attackerLosesNonRefundableFee`) verifies this: the attacker recovers all of `vMin` but cannot recover `nonRefundableFee`. Net loss = `nonRefundableFee`, which is the real Sybil cost.

**Corrected invariant.** At 5 gwei anchor gas price and $\kappa = 4$:

$$\text{nonRefundableFee} > \kappa \times \text{c\_credit}$$

$$0.01\text{ ETH} > 4 \times 500,000 \times 5 \times 10^{-9}\text{ ETH/gas}$$

$$0.01\text{ ETH} > 0.01\text{ ETH} \quad \mathbf{\times} \text{ (tight at 5 gwei; satisfied with margin at lower gas prices)}$$

The invariant holds strictly below 5 gwei and provides a $5\times$ margin at 1 gwei. In practice the fee should be set relative to the expected gas price at spend time.

---

### 3.3 Replay Prevention

`proof.scope = uint256(userOpHash)` uses the ERC-4337 user-operation hash as the Semaphore v4 external nullifier. The ZK circuit produces a unique `nullifier = Poseidon(identity_nullifier, scope)`. Because `scope` is unique per UserOp (includes nonce, sender, callData, gas limits, EntryPoint address, chain ID), the nullifier is unique per credit-spend attempt. Once marked in `_nullifiers`, any replay of the same credit (same identity, same scope) is rejected. Using a different scope produces a different nullifier, but spending a credit with a different scope requires a new proof — which requires knowing the private identity, which only the original depositor possesses.

---

### 3.4 ERC-7562 Bundler Safety

The mirror-and-stake pattern satisfies ERC-7562's storage access rules:

* `BootstrapPaymaster.validatePaymasterUserOp` reads only `this._eligible` and `this._used`.
* `CreditPaymaster.validatePaymasterUserOp` reads only `this._merkleRoot` and `this._nullifiers`.
* Both are populated in the execution phase (not validation phase) by `AnnouncementRegistry.announceAndFund` and `CreditPool.deposit`, respectively.
* The Groth16 verification (`ecMul`, `ecAdd`, `ecPairing` precompiles) is a pure computation — no storage reads or forbidden opcodes.

---

## 4. Implementation

**Language / toolchain:** Solidity 0.8.28, via-IR enabled, optimizer 200 runs, Foundry (forge 0.3).

**External dependencies:**

* `eth-infinitism/account-abstraction` v0.7 — `IPaymaster`, `PackedUserOperation`, `UserOperationLib`, `EntryPoint`, `EntryPointSimulations`
* `semaphore-protocol/semaphore` v4 — `LeanIncrementalMerkleTree` (LeanIMT), `SemaphoreVerifier` (BN254 Groth16), `ISemaphore.SemaphoreProof`
* `OpenZeppelin/openzeppelin-contracts` — `MessageHashUtils` (EIP-712 hashing, used by EntryPoint)

**Code size:**

| Contract | Lines |
| --- | --- |
| AnnouncementRegistry | 126 |
| BootstrapPaymaster | 113 |
| CreditPool | 104 |
| CreditPaymaster | 193 |
| EligibilityLogic | 32 |
| NullifierLogic | 23 |
| **Total (production)** | **591** |
| Test suite | 1,354 |

Circular constructor dependency (`CreditPaymaster` needs `CreditPool` address; `CreditPool` needs `CreditPaymaster` address) is resolved deterministically using `vm.computeCreateAddress(deployer, nonce + k)` to pre-compute all addresses before any deployment.

---

## 5. Evaluation

### 5.1 Gas Costs (Measured, Foundry EVM)

| Operation | Gas (median) | Notes |
| --- | --- | --- |
| `announceAndFund()` | **150,743** | Includes announce emit + 2 CALL (burn + forward) + 2 mirrorEligible SSTOREs. Foundry EVM charges NEWACCOUNT (25,000) for first ETH send to address(0); on mainnet ~125,000 (NEWACCOUNT does not apply — address(0) has balance) |
| `CreditPool.deposit()` | **143,002** | LeanIMT leaf insertion + Poseidon hash + mirrorRoot SSTORE |
| `BootstrapPaymaster.validatePaymasterUserOp()` | **30,070** | 2 SLOAD + selector check + 1 SSTORE (`_used`) |
| `CreditPaymaster.validatePaymasterUserOp()` | **63,072** | 2 SLOAD + scope/message check + MockVerifier (~2,366 gas); real verifier: see §5.2 |
| `CreditPaymaster.validatePaymasterUserOp()` (real Groth16) | **$\approx$285,902** | Derived: 63,072 $-$ 2,366 (mock) + 225,733 (measured real verifier) |

All figures are median from `forge test --gas-report` across all test invocations.

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

Both paymasters were validated against the full ERC-4337 v0.7 validation dispatch using `EntryPointSimulations.simulateValidation` on a local Foundry fork.

| Paymaster | preOpGas | paymasterValidationData | Staked |
| --- | --- | --- | --- |
| BootstrapPaymaster | 80,819 | 0 (SUCCESS) | 0.5 ETH |
| CreditPaymaster | 93,902 | 0 (SUCCESS) | 0.5 ETH |

`paymasterValidationData = 0 = SIG_VALIDATION_SUCCESS` (no time range, no aggregator). Both paymasters pass the real EntryPoint dispatch without reverting under any scenario tested.

**Engineering note on CreditPaymaster (v1.1 fix):** The original design stored the Semaphore proof at `paymasterAndData[52:]`, which included proof bytes in `paymasterDataKeccak` $\rightarrow$ `userOpHash`. Since `proof.scope` must equal `userOpHash`, this created a circular dependency with no pre-computable solution. The fix adopts the ERC-4337 `PAYMASTER_SIG_MAGIC` convention (`0x22e325a297439656`): appending `uint16(proofLen)` $\mid\mid$ `magic` to `paymasterAndData` instructs `paymasterDataKeccak` to exclude proof bytes from the hash. `userOpHash` is then stable before proof generation, breaking the cycle. The stable hash is confirmed by asserting `getUserOpHash(op_placeholder) == getUserOpHash(op_real_proof)` in the test.

**Implementation subtlety:** `EntryPointSimulations.__domainSeparatorV4` is stored in a regular storage slot (not an immutable) and is initialized lazily inside `_simulationOnlyValidations()`. Calling `getUserOpHash()` before any `simulateValidation` returns a hash with domain separator = 0, mismatching what the internal validation computes. The test works around this by running one successful bootstrap `simulateValidation` in `setUp()` to initialize the slot before any `getUserOpHash()` calls are made.

---

### 5.4 Test Coverage

| Test file | Tests | What is verified |
| --- | --- | --- |
| AnnouncementRegistry.t.sol | 8 | Happy path, sub-minimum rejection, fee/vMin updates |
| BootstrapPaymaster.t.sol | 8 | Eligibility, already-used rejection, wrong callData |
| CreditPool.t.sol | 6 | Leaf insertion, root update, double-deposit rejection |
| CreditPaymaster.t.sol | 10 | Valid proof, bad root, spent nullifier, gas cap, scope check |
| Integration.t.sol | 1 | Full 3-step end-to-end: announce $\rightarrow$ bootstrap $\rightarrow$ anonymous spend |
| SybilResistance.t.sol | 6 | Self-dealing round trip, sub-minimum boundary, eligibility |
| ReplayResistance.t.sol | 2 | Same nullifier rejected, different nullifiers both accepted |
| RealGroth16.t.sol | 2 | Real BN254 Groth16 gas measurement at depth 1 and 16 |
| SimulateValidation.t.sol | 2 | Full ERC-4337 dispatch for both paymasters |
| **Total** | **45** | **All pass** |

---

## 6. Protocol Flow Summary

### Phase 1 — ANNOUNCE (on-chain, linkable)

* Sender calls: `AnnouncementRegistry.announceAndFund{value: vMin + fee}(stealthAddr, ...)`
* $\rightarrow$ fee burned to `address(0)` `[Sybil cost: irrecoverable]`
* $\rightarrow$ `vMin` forwarded to `stealthAddr` `[gas seed]`
* $\rightarrow$ ERC-5564 Announcement emitted `[recipient can scan and derive key]`
* $\rightarrow$ eligibility mirrored atomically `[bootstrapPM._eligible, creditPool._eligible]`



### Phase 2 — BOOTSTRAP (ERC-4337, gas-free for stealth addr)

* Stealth addr submits UserOp: `callData = CreditPool.deposit(commitment)`
* Bundler validates via BootstrapPaymaster:
* $\rightarrow$ checks `_eligible[sender]` (own storage), checks `callData` selector
* $\rightarrow$ marks `_used[sender] = true`
* $\rightarrow$ returns `SIG_VALIDATION_SUCCESS`


* EntryPoint executes `callData`:
* $\rightarrow$ `CreditPool.deposit(commitment)` inserts leaf into LeanIMT
* $\rightarrow$ new root pushed to `CreditPaymaster._merkleRoot`
* `[stealth addr pays zero gas; never reuses this identity on-chain]`



### Phase 3 — SPEND (ERC-4337, fully anonymous)

* Any address submits UserOp with `paymasterAndData = [..., SemaphoreProof, len, MAGIC]`
* Bundler validates via CreditPaymaster:
* $\rightarrow$ checks `_merkleRoot` match (own storage)
* $\rightarrow$ checks `proof.scope == userOpHash` (binds proof to this op)
* $\rightarrow$ checks `_nullifiers[nullifier] = false` (own storage)
* $\rightarrow$ runs `SemaphoreVerifier.verifyProof` (BN254 Groth16, ~225,733 gas)
* $\rightarrow$ marks nullifier spent
* $\rightarrow$ returns `SIG_VALIDATION_SUCCESS`


* `[sender ≠ depositor; no on-chain link between phase 2 and phase 3]`

---

## 7. Limitations and Future Work

* **One credit per stealth address.** `CreditPool.deposit` allows exactly one insertion per eligible address. An address that has deposited cannot deposit again, even with a fresh identity commitment. Lifting this restriction requires removing the `_used` check in `deposit()`, which weakens the Sybil bound.
* **Scanning cost.** Recipients must scan ERC-5564 announcements to discover funds. At high announcement volume this is computationally expensive. Stealth address meta-address registries (ERC-6538) can reduce the scan set.
* **V_MIN utility.** The forwarded `vMin` funds bootstrap gas. After `BootstrapPaymaster` sponsors the deposit, the remaining `vMin` balance on the stealth address is small and serves no further protocol purpose. It is spendable as normal ETH.
* **Gas cap conservatism.** `MAX_CREDIT_GAS` = 500,000 was set conservatively. With real Groth16 verification costing 225,733 gas, a credit-sponsored transaction has a remaining budget of ~274,267 gas for the call itself — sufficient for most DeFi operations but not complex multi-step calls.
* **Paymaster signature convention.** The `PAYMASTER_SIG_MAGIC` fix (§5.3) changes the `paymasterAndData` encoding in a breaking way. Off-chain clients (bundlers, wallets, proof generators) must adopt the new encoding. A version byte at offset 52 could ease migration.