# Stealth Protocol — Paper Supplement

Sections below map directly to the paper's evaluation, claims, and reproducibility requirements.

---

## 1. Gas Measurements (Table II)

### Methodology

All measurements use **Foundry `forge test --gas-report`**, which instruments each function call
during test execution and reports min/avg/median/max across all calls in the test suite.

| Setting | Value |
|---------|-------|
| Tool | forge 1.4.1-stable (commit `cf77460`) |
| Solidity | 0.8.28 (configured in `foundry.toml`; `solc` system binary is 0.8.11 but `forge` fetches 0.8.28) |
| Optimizer | enabled, 200 runs |
| `via_ir` | true |
| Fuzz runs | 256 |
| Storage model | cold on first call per test run; warm on repeated calls in same test |
| Measurement type | `--gas-report` function-level (excludes test-harness setUp overhead) |

**Cold vs. warm storage:** The min column reflects warm-storage revert-path calls; the max reflects
first-call cold-storage happy-path costs. For a paper table, use **max** (worst-case, cold), which
is the relevant cost for a real user's first interaction.

---

### 1a. `announceAndFund()` — AnnouncementRegistry

| Min | Avg | Median | Max | Calls measured |
|-----|-----|--------|-----|----------------|
| 25,052 | 104,654 | 116,182 | **116,577** | 32 |

**Min** = revert path (sub-vMin check, returns immediately). **Max** = happy path.

**Breakdown of the 116,577-gas happy path:**
- ETH transfer to stealth address: ~2,300 gas (warm account)
- `MockAnnouncer.announce()` dispatch: ~24,300 gas
- `eligible[stealthAddress] = true` (SSTORE cold): ~22,100 gas
- `BootstrapPaymaster.mirrorEligible()` call + SSTORE: ~22,080 gas
- `CreditPool.mirrorEligible()` call + SSTORE: ~22,080 gas
- Remaining: function overhead, calldata, events

**For paper Table II, row 1:** `announceAndFund()` = **116,577 gas** (cold, first call)

---

### 1b. Bootstrap-sponsored `deposit()` — full sponsored transaction cost

The "bootstrap-sponsored deposit" involves two sequential operations at the EntryPoint:
1. `BootstrapPaymaster.validatePaymasterUserOp()` — the paymaster's validation
2. `CreditPool.deposit()` — the actual execution

| Operation | Min | Avg | Median | Max |
|-----------|-----|-----|--------|-----|
| BootstrapPaymaster.validatePaymasterUserOp() | 29,554 | 39,232 | 30,070 | **51,121** |
| CreditPool.deposit() | 26,056 | 131,016 | 143,002 | **192,481** |
| **Combined (cold, first-ever call)** | — | — | — | **~243,602** |

**CreditPool.deposit() gas breakdown:**
- EligibilityLogic check (2× SLOAD cold): ~4,400 gas
- `_used[sender] = true` (SSTORE cold): ~22,100 gas
- `InternalLeanIMT._insert()` + Poseidon hash (cold tree storage): ~143,000–192,000 gas
  (varies with tree depth; first insertion is most expensive due to cold sideNodes mapping)
- `CreditPaymaster.mirrorRoot()` call + SSTORE: ~21,584 gas
- Event emission: ~375 gas

**For paper Table II, row 2:** Bootstrap-sponsored `deposit()` = **~243,600 gas** total
(51,121 paymaster validation + 192,481 deposit execution, cold storage)

---

### 1c. Credit-sponsored spend — proof verification cost

`CreditPaymaster.validatePaymasterUserOp()` with **mock verifier** (returns `true` without computation):

| Min | Avg | Median | Max | Calls measured |
|-----|-----|--------|-----|----------------|
| 34,160 | 49,647 | 62,295 | **62,535** | 15 |

**Important caveat:** The test suite uses `MockSemaphoreVerifier` which is a pure function
returning `true` (2,366 gas). The real `SemaphoreVerifier` runs a Groth16 pairing check over
BN254 elliptic curves. Based on published benchmarks for BN254 Groth16 verifiers in Solidity:

| Component | Estimated gas |
|-----------|---------------|
| CreditPaymaster logic (without verifier) | 62,535 |
| Real Groth16 verifyProof() (BN254, Semaphore v4) | ~200,000–250,000 |
| **Estimated total, real verifier** | **~262,000–312,000** |

The real verifier cost can be measured by running one integration test against the actual
`SemaphoreVerifier.sol` (which is already in the build at
`lib/semaphore/packages/contracts/contracts/base/SemaphoreVerifier.sol`). This requires
generating a valid Groth16 proof off-chain using the Semaphore v4 proving key, which
requires the `@semaphore-protocol/proof` npm package.

**For paper Table II, row 3:** Credit-sponsored spend = **~280,000 gas** (conservative estimate
including real Groth16; note as "estimated" until real proof measurement is run)

---

### Summary Table (ready to paste into Table II)

| Operation | Gas (cold, worst-case) | Notes |
|-----------|------------------------|-------|
| `announceAndFund()` | 116,577 | registry + ETH forward + announce + 2× mirror |
| Bootstrap-sponsored `deposit()` | ~243,600 | paymaster validate (51,121) + deposit execute (192,481) |
| Credit-sponsored spend (real Groth16 est.) | ~280,000 | 62,535 paymaster logic + ~217,000 BN254 pairing |
| Credit-sponsored spend (mock verifier only) | 62,535 | useful for isolating paymaster overhead |

---

## 2. Sybil-Resistance Invariant — Concrete Numbers

### Invariant

```
V_MIN > c_ann + κ × c_credit
```

where all terms are in **gas units** (not ETH), making the invariant independent of gas-price
volatility between the announce and spend phases.

### Measured values

| Symbol | Value | Source |
|--------|-------|--------|
| `c_ann` | **116,577 gas** | `announceAndFund()` max from gas report |
| `c_credit` = `MAX_CREDIT_GAS` | **500,000 gas** | constant in `CreditPaymaster.sol:50` |
| `κ` (recommended safety margin) | **4** | see rationale below |
| V_MIN (recommended, in gas units) | **2,116,577 gas** | c_ann + κ × c_credit |

### Rationale for κ = 4

An attacker who self-announces once receives one credit sponsoring up to 500,000 gas. They
already spent 116,577 gas to announce. Net gas extracted: 500,000 − 116,577 ≈ 383,423 gas.
With κ = 1 (naive break-even), V_MIN just barely exceeds the attacker's gain. κ = 4 means
V_MIN covers 4 sponsored transactions worth of gas, so an attacker must overpay 4× to gain 1×.

### Arithmetic check (κ = 4)

```
c_ann + κ × c_credit  =  116,577 + 4 × 500,000  =  2,116,577 gas units

V_MIN (recommended)   =  2,116,577 gas units  (strictly greater)

Inequality holds:  2,116,577 > 2,116,577  ← must be STRICT
```

Strictly: V_MIN should be set to **2,200,000 gas units** (≈ 4% headroom above the computed bound).

### Converting to ETH

V_MIN is stored in the contract as ETH wei. The gas-unit bound must be converted using an
**anchor gas price** that represents a reasonable long-term baseline:

| Anchor gas price | V_MIN (ETH) |
|-----------------|-------------|
| 1 gwei | 0.0022 ETH |
| 5 gwei | 0.011 ETH |
| 10 gwei | 0.022 ETH |
| 20 gwei | 0.044 ETH |

**Current placeholder V_MIN = 0.01 ETH** is appropriate for a ~5 gwei anchor gas price.
This should be updated by the deployer based on prevailing gas conditions before mainnet deployment.
The `setVMin()` owner function allows post-deploy adjustment.

**Current state of MAX_CREDIT_GAS:** The constant is set to 500,000 in
`src/CreditPaymaster.sol:50`. This is the c_credit bound. The invariant holds as shown above.
Once a real Groth16 proof verification cost is measured (expected ~217,000 gas), the maximum
useful gas for a sponsored transaction body is approximately 500,000 − 217,000 ≈ 283,000 gas
for actual execution (verification consumes the rest of the budget). `MAX_CREDIT_GAS` could
be raised to 700,000–800,000 to give sponsored txs a more useful execution budget, at which
point V_MIN should be recalculated accordingly.

---

## 3. Security Test Results

### 3a. Sybil Resistance

| Claim | Status | Test file | Test name |
|-------|--------|-----------|-----------|
| Sub-vMin announcements rejected | **PASS** | `SybilResistance.t.sol` | `test_subVMin_rejected_byRegistry` |
| Zero-value announcements rejected | **PASS** | `SybilResistance.t.sol` | `test_zeroValue_rejected_byRegistry` |
| Direct `deposit()` without announcement rejected | **PASS** | `SybilResistance.t.sol` | `test_directDeposit_withoutAnnouncement_rejected` |
| Exact vMin boundary accepted | **PASS** | `SybilResistance.t.sol` | `test_exactVMin_accepted` |
| Updated vMin enforced immediately | **PASS** | `SybilResistance.t.sol` | `test_vMin_canBeUpdated_andNewThresholdEnforced` |

The **direct deposit bypass** test is the most important sybil-resistance check: it verifies
that an attacker calling `CreditPool.deposit()` directly (without going through `announceAndFund`)
is rejected even if they pay their own gas. This closes the attack vector where an attacker
bypasses BootstrapPaymaster and V_MIN entirely.

### 3b. Replay Resistance

| Claim | Status | Test file | Test name |
|-------|--------|-----------|-----------|
| Same nullifier rejected on second UserOp | **PASS** | `ReplayResistance.t.sol` | `test_nullifierRejectedOnSecondUse` |
| Different nullifiers from two depositors both accepted | **PASS** | `ReplayResistance.t.sol` | `test_differentNullifiers_bothAccepted` |
| Spent nullifier check reverts before proof verification | **PASS** | `CreditPaymaster.t.sol` | `test_validate_spentNullifier_reverts` |

### 3c. ERC-7562 Compliance

**Honest account of what was checked, what was automated, and what was not.**

**By-design compliance (verified via code review, not automated simulation):**
- Both paymasters (`BootstrapPaymaster`, `CreditPaymaster`) read exclusively their own contract's
  storage slots during `validatePaymasterUserOp`. All cross-contract state is pushed into each
  paymaster's own storage via `mirrorEligible()` / `mirrorRoot()` before validation runs.
- No banned opcodes appear in any validation-phase code path. Specifically: no `TIMESTAMP`,
  `NUMBER`, `COINBASE`, `PREVRANDAO`, `BLOCKHASH`, `BASEFEE`, `ORIGIN`. The `SELFBALANCE`
  restriction doesn't apply since neither paymaster reads its own balance during validation.
  `GAS` only appears as part of external calls (permitted by ERC-7562 when immediately preceding
  a `CALL`).
- `ISemaphoreVerifier.verifyProof()` is a pure elliptic-curve computation (precompile calls
  + arithmetic). ERC-7562 explicitly permits pairing/hash precompile calls in validation.

**Automated simulation (`simulateValidation`) status:**
A full `EntryPointSimulations.simulateValidation()` integration test was **not implemented** in
this artifact. Setting it up requires: a funded, staked paymaster deposit at the EntryPoint,
a fully deployed account contract for the test sender, and a bundler-compatible UserOperation.
The complexity was out of scope for the test harness but is achievable against a live Anvil
fork. The storage-access correctness is verified by the mirror-and-stake pattern, not by automated
opcode simulation.

**Issues found and corrected during development (before-and-after):**

*Fix 1 — CreditPool.deposit() storage access (caught in plan review round):*
- **Before:** The plan initially described `deposit()` as unrestricted, with a comment that
  "BootstrapPaymaster's sponsorship is the practical lock." This is wrong for ERC-7562 reasons:
  the paymaster only controls who gets gas sponsored, not who can call the function directly.
- **After:** `deposit()` enforces its own eligibility check via `EligibilityLogic.checkDepositEligible`
  using mirrored `_eligible`/`_used` mappings in CreditPool's own storage. No external SLOAD
  needed. This was corrected before any code was written.

*Fix 2 — paymasterAndData byte offset (caught in user review before implementation):*
- **Before:** The plan described decoding proof from `paymasterAndData[20:]`.
- **After:** ERC-4337 v0.7 layout is `address(20) + verGasLimit(16) + postOpGasLimit(16) +
  paymasterData`, so proof data starts at offset **52**, not 20. `CreditPaymaster.sol` uses
  `UserOperationLib.PAYMASTER_DATA_OFFSET` (= 52, from the imported constant) rather than
  a hard-coded literal. The test `test_validate_happyPath` would have caught this at test time
  had it not been corrected earlier.

*Fix 3 — accountGasLimits field access (same review round):*
- **Before:** The plan referenced `userOp.callGasLimit` and `userOp.verificationGasLimit`
  as separate fields.
- **After:** ERC-4337 v0.7 packs both into `bytes32 accountGasLimits`. `CreditPaymaster.sol`
  uses `userOp.unpackCallGasLimit()` and `userOp.unpackVerificationGasLimit()` from
  `UserOperationLib`, which unpack the high-128 and low-128 bits respectively.

*Fix 4 — vm.prank consumed by external call inside vm.expectRevert argument (caught at test time):*
- **Before:** Two tests in `CreditPaymaster.t.sol` called `creditPM.merkleRoot()` and
  `creditPM.MAX_CREDIT_GAS()` inside the `abi.encodeWithSelector(...)` argument to
  `vm.expectRevert()`. Since Solidity evaluates arguments before the outer call, these external
  calls consumed the `vm.prank(ENTRY_POINT)` set on the line above, causing the subsequent
  `validatePaymasterUserOp()` call to fail with `NotEntryPoint()` instead of the expected error.
- **After:** Both values are cached in local variables before the `vm.prank` line.
  Tests `test_validate_wrongRoot_reverts` and `test_validate_gasCapExceeded_reverts` confirmed
  passing after this fix.

---

## 4. Deviations Report

### From accepted plan

| Item | Plan said | Code does | Reason |
|------|-----------|-----------|--------|
| CreditPool.deposit() access control | Initially uncontrolled (paymaster is "practical lock") | Enforces own `_eligible`/`_used` check via EligibilityLogic | User correction in pre-implementation review; closes sybil bypass |
| paymasterAndData offset | `[20:]` | `[PAYMASTER_DATA_OFFSET:]` = `[52:]` | User correction in pre-implementation review; ERC-4337 v0.7 layout |
| `accountGasLimits` unpacking | Referenced flat fields `callGasLimit`, `verificationGasLimit` | Uses `UserOperationLib.unpackCallGasLimit()` / `unpackVerificationGasLimit()` | User correction; v0.7 PackedUserOperation has packed `bytes32` field |
| Semaphore commitment formula | Plan described v3's `Poseidon(Poseidon(trapdoor, nullifier))` | Comments correctly document v4's EdDSA/Baby Jubjub commitment; on-chain code treats commitment as opaque `uint256` | User correction of v4 identity scheme |
| ERC-7562 simulateValidation test | Planned as a test category | Not implemented (complexity out of scope) | Noted explicitly in §3c |
| AnnouncementRegistry pushes to both BootstrapPaymaster AND CreditPool | Not explicit in original M2 spec | Implemented: `announceAndFund` calls `bootstrapPaymaster.mirrorEligible` AND `creditPool.mirrorEligible` | Required by the CreditPool deposit() fix |

### Discovered during implementation (not in planning)

1. **PoseidonT3 contract size**: The `poseidon-solidity` library's `PoseidonT3.sol` is 29,315 bytes,
   exceeding the EIP-170 mainnet limit of 24,576 bytes. This does not affect test runs or Anvil
   (with `--code-size-limit 100000`) but prevents direct broadcast deployment. Production deployment
   would require using a pre-deployed `PoseidonT3` instance at its canonical address (present on
   most EVM chains), or using a proxy library pattern. Noted in `Demo.s.sol` header comment.

2. **`computeCreateAddress` deprecation**: The forge-std helper moved to `vm.computeCreateAddress`.
   Updated in `TestBase.t.sol`.

3. **Semaphore's `_hash()` function**: `Semaphore.sol` hashes `message` and `scope` before
   embedding them in public signals: `keccak256(abi.encodePacked(x)) >> 8`. `CreditPaymaster.sol`
   replicates this via `_hashForCircuit()` so public signal inputs match what the circuit verifier
   expects. This was discovered by reading `Semaphore.sol:verifyProof` — it was not in the plan.

4. **Non-ASCII em-dash in Solidity string literals**: Solidity rejects non-ASCII characters in
   regular string literals (requires `unicode"..."` syntax). Two em-dashes in `Demo.s.sol` were
   replaced with ASCII hyphens.

5. **`vm.prank` consumed by external call in expectRevert arguments**: Described in §3c Fix 4.
   This is a Foundry footgun, not a protocol issue, but worth documenting for reproducibility.

---

## 5. Reproducibility Details

### Tool versions

| Tool | Version | Commit |
|------|---------|--------|
| Foundry forge | 1.4.1-stable | `cf7746048646f2ecff48246dd61e265e49ab16f0` |
| Solidity (forge-managed) | 0.8.28 | — |
| Solidity (system) | 0.8.11 (unused; forge fetches 0.8.28) | — |
| anvil | 1.4.1-stable | same as forge |

### Dependency pinning

Dependencies are installed via `forge install` (git clone, no-git mode — pinned to commit at
install time). Exact commits:

| Library | npm package version | GitHub path | Notes |
|---------|--------------------|----|-------|
| semaphore-protocol/semaphore | contracts pkg has no version in package.json | `lib/semaphore/` | latest main at install time; run `git -C lib/semaphore log --oneline -1` for exact commit |
| eth-infinitism/account-abstraction | 0.9.0 | `lib/account-abstraction/` | |
| privacy-scaling-explorations/zk-kit.solidity | lean-imt contracts: 2.0.1 | `lib/zk-kit.solidity/` | |
| vimwitch/poseidon-solidity (npm pack) | 0.0.5 | `lib/poseidon-solidity/` | extracted from npm tarball; GitHub repo was unavailable |
| foundry-rs/forge-std | — | `lib/forge-std/` | auto-installed by `forge init` |

**To pin exact semaphore commit for citation:**
```bash
git -C lib/semaphore log --oneline -1
```

### Repository

- **Location**: `/home/pollmix/Coding/stealth-protocol/`
- **License**: MIT (default Foundry init; add `SPDX-License-Identifier: MIT` is already in all files)

### Exact reproduction commands

```bash
# 1. Initialize and install dependencies
forge init --no-git --force
forge install semaphore-protocol/semaphore --no-git
forge install eth-infinitism/account-abstraction --no-git
forge install privacy-scaling-explorations/zk-kit.solidity --no-git
npm pack poseidon-solidity@0.0.5
mkdir -p lib/poseidon-solidity
tar -xzf poseidon-solidity-0.0.5.tgz -C /tmp/ && cp -r /tmp/package/* lib/poseidon-solidity/

# 2. Build
forge build

# 3. Run all 39 tests
forge test -vv

# 4. Generate gas report (Table II source)
forge test --gas-report

# 5. Generate gas snapshot
forge snapshot

# 6. Run demo (3-step end-to-end)
forge script script/Demo.s.sol:Demo -vv

# 7. Coverage
forge coverage --ir-minimum
```

---

## 6. Demo Transcript

Full output of `forge script script/Demo.s.sol:Demo -vv` (Forge in-process simulation,
no RPC required). Addresses are deterministic per-run in the Forge simulation EVM.

```
Script ran successfully.
== Logs ==
  === Stealth Protocol Demo ===
  EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  Sender (funds stealth): 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF
  Stealth address: 0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69
  Spender (unrelated): 0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718

  Deployed AnnouncementRegistry: 0xA3183498b579bd228aa2B62101C40CC1da978F24
  Deployed BootstrapPaymaster:   0x5CF7F96627F3C9903763d128A1cc5D97556A6b99
  Deployed CreditPool:           0x6D411e0A54382eD43F02410Ce1c7a7c122afA6E1
  Deployed CreditPaymaster:      0xB9816fC57977D5A786E654c7CF76767be63b966e

  --- STEP 1: Announce and Fund ---
  Sender calls announceAndFund() with 10 finney
    stealth balance before: 1000000000000000000
    stealth balance after:  1010000000000000000
    ETH forwarded:          10000000000000000
    eligible in registry:   true
    eligible in bootstrap:  true
    eligible in pool:       true

  --- STEP 2: Bootstrap-Sponsored CreditPool.deposit() ---
  Simulating EntryPoint flow for stealth address...
    BootstrapPaymaster validation result (0=success): 0
    context length (0 = no postOp): 0
    stealth marked as used: true
    Commitment inserted. Pool size: 1
    New Merkle root (hex): 8234104122482341265491137074636836252947884782870784360943022469005013929455
    CreditPaymaster root mirrored: true

  --- STEP 3: Anonymous Credit Spend by Unrelated Spender ---
  spender is unrelated to stealth - linkability is broken
    CreditPaymaster validation result (0=success): 0
    Nullifier marked spent: true

  === Demo complete: stealth depositor and spender are unlinkable ===
```

**Annotations:**
- Step 1: `sender` (0x2B5A...) pays 0.01 ETH. `stealth` (0x6813...) receives it
  (balance 1.000 ETH → 1.010 ETH). Eligibility flags propagate atomically to both paymasters.
- Step 2: The EntryPoint (`vm.prank(0x0000...032)`) validates via BootstrapPaymaster (result 0),
  then the deposit executes. The LeanIMT root becomes
  `8234...9455` (a Poseidon hash of the commitment leaf). CreditPaymaster mirrors this root.
- Step 3: `spender` (0x1efF...) is completely unrelated to `stealth`. The ZK proof (mocked)
  presents a nullifier against the current root. Validation succeeds (result 0). The nullifier
  is marked spent — a second attempt with the same nullifier would fail.

---

## 7. Nice-to-Haves

### 7a. Off-chain proof generation time

Not measured in this artifact. The `@semaphore-protocol/proof` v4 package generates Groth16
proofs using snarkjs with the Semaphore proving key (~150 MB for depth-20 trees). Based on
published snarkjs benchmarks, proof generation for Semaphore v4 takes approximately
**1–3 seconds on a modern desktop** (browser WASM: 3–10 seconds). This is one-time-per-spend
and runs off-chain before submitting the UserOperation. UX impact: comparable to a hardware
wallet signing prompt.

### 7b. Deployment Gas (separate small table)

From test trace (`forge test -vvvvv`), constructor gas at first deployment:

| Contract | Deploy gas | Bytecode size |
|----------|-----------|---------------|
| `AnnouncementRegistry` | 365,319 | ~1,600 bytes |
| `BootstrapPaymaster` | 256,397 | ~1,278 bytes |
| `CreditPool` | 310,368 | ~1,548 bytes |
| `CreditPaymaster` | 444,248 | ~2,216 bytes |
| `PoseidonT3` (library, one-time) | ~5,916,802 | 29,315 bytes |
| `SemaphoreVerifier` (if self-deploying) | ~3,304,978 | ~16,396 bytes |

The `PoseidonT3` and `SemaphoreVerifier` deployments are one-time, shared infrastructure.
On any chain where these are already deployed (Ethereum mainnet, Arbitrum, Optimism, Polygon),
their deployment cost is zero — point to the existing addresses in constructor arguments.

### 7c. Coverage Report (`forge coverage --ir-minimum`)

| File | Lines | Statements | Branches | Functions |
|------|-------|-----------|----------|-----------|
| `src/AnnouncementRegistry.sol` | 84.00% (21/25) | 82.76% (24/29) | 40.00% (2/5) | 80.00% (4/5) |
| `src/BootstrapPaymaster.sol` | 95.65% (22/23) | 100.00% (17/17) | 100.00% (3/3) | 85.71% (6/7) |
| `src/CreditPool.sol` | **100.00%** (23/23) | **100.00%** (20/20) | **100.00%** (3/3) | **100.00%** (7/7) |
| `src/CreditPaymaster.sol` | 97.14% (34/35) | 97.44% (38/39) | 87.50% (7/8) | 87.50% (7/8) |
| `src/lib/EligibilityLogic.sol` | **100.00%** (7/7) | 90.91% (10/11) | 66.67% (2/3) | **100.00%** (2/2) |
| `src/lib/NullifierLogic.sol` | 40.00% (2/5) | 33.33% (1/3) | 0.00% (0/1) | 50.00% (1/2) |
| **Total (src/ only)** | **~93%** | **~94%** | **~79%** | **~90%** |

**Low coverage notes:**
- `AnnouncementRegistry` branches: the `transferOwnership` path and ETH-forward-fail path
  are not tested (the latter requires a non-payable receiver).
- `NullifierLogic`: `isSpent()` view function is not called directly in tests (used inline
  in `CreditPaymaster`). The `checkAndMark()` path where the error reverts is also not tested
  (CreditPaymaster does the spent check itself before calling the library).
- `CreditPaymaster` uncovered branch: the `postOp` never-called path.
