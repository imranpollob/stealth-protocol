# PrivGas — Paper Supplement

Maps every empirical claim in the paper to the artifact evidence that supports it, and states
plainly what the artifact does **not** establish. Section numbers, symbols, and table numbers
follow the paper.

**Notation:** $F$ non-refundable fee; $V_{\min}$ minimum forwarded value; $B_{\text{boot}}$,
$B_{\text{spend}}$ maximum sponsorship costs; $p_{\max}$ maximum accepted gas price; $\kappa$
safety margin; $C$ commitment; $R$ Merkle root; $N$ nullifier;
$D = \operatorname{uint256}(\textit{userOpHash})$; $S_{\text{credit}}$ fixed credit scope.

Environment: Foundry `1.4.1-stable`, Solidity `0.8.28`, optimizer on (200 runs), `via_ir`,
account-abstraction v0.9 EntryPoint, Semaphore v4 verifier. Suite status: **65 passed,
0 failed**.

---

## 1. Claim-to-evidence map

| # | Paper claim | Where in paper | Evidence | Command |
|---|---|---|---|---|
| 1 | Credit validation costs 284,527 gas, 43.1 % below the 500,000-gas ERC-4337 limit | Abstract, §I, Table II, §VII | `CreditPaymaster.validatePaymasterUserOp` max, real verifier | `forge test --gas-report` |
| 2 | Isolated Groth16 verification costs 225,733 gas | Table II, §VI | `test/RealGroth16.t.sol` | `forge test --match-contract RealGroth16Test -vv` |
| 3 | Six Spend-phase correctness cases | Table III, §VI | `test/FunctionalCorrectness.t.sol` | `forge test --match-contract FunctionalCorrectnessTest -vv` |
| 4 | Bootstrap and Spend both execute through `EntryPoint.handleOps` | §VI | `BootstrapSponsorshipBoundTest`, `FunctionalCorrectnessTest` | `forge test` |
| 5 | 65 passing tests | §VI | whole suite | `forge test` |
| 6 | Both paymasters enforce a 0.005 ETH sponsorship cap and a 10 gwei gas-price cap | §VI | §3 below | `forge test --match-contract BootstrapSponsorshipBoundTest -vv` |
| 7 | $F = 0.021 > 2(0.005+0.005) = 0.020$ ETH | §VI, Eq. (1) | §3 below | arithmetic; bound enforced on-chain |
| 8 | ERC-7562-oriented storage design, preliminarily checked | §VI | `test/SimulateValidation.t.sol` | `forge test --match-contract SimulateValidationTest -vv` |
| 9 | Prototype accepts only the latest mirrored Merkle root | §VI | single `_merkleRoot` slot; no history structure | `test_unacceptedMerkleRoot_rejected` |

### Goals and lemmas

| Paper item | Statement | Artifact evidence |
|---|---|---|
| **G1** / **Lemma 1** | Sybil resistance: a credit cannot be manufactured below the non-refundable cost | §3 below; `SybilResistanceTest` (6 tests), on-chain fee bound |
| **G2** / **Lemma 2** | Gas top-up unlinkability and commitment-index privacy | Structural: no recipient-side top-up in the flow; the proof reveals only $R$ and $N$. Not quantified — see §6 |
| **G3** / **Lemma 3** | One-credit redemption | `test_validProof_previouslySpentNullifier_rejected`; fixed $S_{\text{credit}}$ makes $N$ a stable spend marker |

Lemma 2 is a design property, not a measured one. The artifact demonstrates that the paymaster
receives no leaf index and that the flow contains no recipient-side top-up; it does not measure
anonymity-set size. Lemmas 1 and 3 are directly exercised by tests.

---

## 2. Functional correctness (paper Table III)

`test/FunctionalCorrectness.t.sol`, all through real `EntryPoint.handleOps`.

| Scenario | Expected | Observed | Test |
|---|---|---|---|
| Valid proof, unspent nullifier, correct sender | Accept | **Accept** | `test_validProof_unspentNullifier_correctSender_accepted` |
| Valid proof, previously spent nullifier | Reject | **Reject** (`NullifierSpent`) | `test_validProof_previouslySpentNullifier_rejected` |
| Proof bound to a different sender | Reject | **Reject** (`WrongMessage`, then `InvalidProof`) | `test_validProof_senderMismatch_rejected` |
| Proof bound to a different operation | Reject | **Reject** (`WrongMessage`, then `InvalidProof`) | `test_validProof_differentUserOperation_rejected` |
| Invalid current Merkle root | Reject | **Reject** (`RootMismatch`) | `test_unacceptedMerkleRoot_rejected` |
| `maxCost > B_spend` | Reject | **Reject** (`MaxCostExceeded`) | `test_maxCostExceedsSponsorshipBudget_rejected` |

Rejections surface as `FailedOpWithRevert(0, "AA33 reverted", <inner error>)`; each test asserts
the exact inner selector, so the *reason* for rejection is pinned, not merely the fact of it.

### Why these are not vacuous

Each test uses genuine `snarkjs groth16.fullProve` output over a 4-member Semaphore group
(`merkleTreeDepth` 2), verified on-chain by the real `SemaphoreVerifier`. `MockSemaphoreVerifier`
is not used anywhere in the file.

**Sender and operation binding are tested twice.** The naive form (submit the proof unchanged)
is rejected by the paymaster's digest equality check. The strong form overwrites `proof.message`
with the *new* operation's hash so that equality passes — and on-chain Groth16 rejects it. Only
the second form demonstrates that binding is enforced by the proof rather than by an `==`.

**Hash derivation is real.** Because `proof.message` must equal a keccak preimage no prover can
invert, fixtures are built in three phases: dump the EntryPoint-computed hashes
(`script/proof/DumpUserOpHashes.s.sol`), prove over them
(`script/proof/generateFunctionalCorrectnessProofs.mjs`), then replay the identical deployment.
Every test asserts `entryPoint.getUserOpHash(op) == proof.message` before submitting.

**Negative control.** Incrementing a single field of one proof point flips the accept case to
`InvalidProof` (`0x09bde339`), confirming the result is gated on the pairing check.

**One credit, one nullifier.** All three fixture proofs share a nullifier because the Semaphore
scope is fixed, so the spent-nullifier case is a genuine double-spend of one credit rather than
two unrelated proofs.

---

## 3. Sybil-resistance bound (paper Eq. (1), G1 / Lemma 1)

$$F > \kappa \cdot (B_{\text{boot}} + B_{\text{spend}})$$

| Symbol | Value | Enforced by |
|---|---|---|
| `B_boot` | 0.005 ETH | `BootstrapPaymaster.MAX_BOOTSTRAP_SPONSORSHIP_COST` |
| `B_spend` | 0.005 ETH | `CreditPaymaster.MAX_SPONSORSHIP_COST` |
| `p_max` | 10 gwei | `MAX_ACCEPTED_MAX_FEE_PER_GAS` (both paymasters) |
| `κ` | 2 | design parameter |
| `F` | 0.021 ETH | `AnnouncementRegistry`, constructor-configured |
| minimum admissible `F` | > 0.020 ETH | `AnnouncementRegistry.MIN_NON_REFUNDABLE_FEE` |

```
B_boot + B_spend      = 0.005 + 0.005 = 0.010 ETH   (1 × 10¹⁶ wei)
κ · (B_boot + B_spend) = 2 × 0.010    = 0.020 ETH   (2 × 10¹⁶ wei)
F                                     = 0.021 ETH   (2.1 × 10¹⁶ wei)

0.021 > 0.020   ✓   strict, 5 % margin
```

### What makes the bound binding

Both caps are checked against the EntryPoint's `maxCost` — its `requiredPrefund`, the largest
amount the paymaster's deposit can be debited — not against gas-field proxies.
`requiredPrefund` sums `verificationGasLimit + callGasLimit + paymasterVerificationGasLimit +
paymasterPostOpGasLimit + preVerificationGas`. A cap on only some of those terms would leave the
account's attacker-controlled verification phase, and the gas price, unbounded.

`test_maxCostExceedsSponsorshipBudget_rejected` and
`test_bootstrapSponsorship_maxCostExceedsBudget_rejected` each construct an operation that stays
inside the per-field gas cap while exceeding the budget, and assert the budget check is what
rejects it. `MIN_NON_REFUNDABLE_FEE` rejects a non-conforming `F` at both construction and
update, so a violating configuration cannot be installed.

### Self-dealing

`SybilResistanceTest.test_selfDealing_roundTrip_attackerLosesNonRefundableFee` runs the full
round trip where the attacker controls both the funding wallet and the stealth address, and
asserts net loss equals exactly $F$. The forwarded $V_{\min}$ is recoverable; $F$ is routed to the
non-recoverable fee sink — implemented as a transfer to `address(0)` — and is not. This is why
Eq. (1) is stated over $F$ alone.

---

## 4. Bootstrap phase

| Property | Test |
|---|---|
| End-to-end sponsored deposit reaches `CreditPool` and the root is mirrored | `test_bootstrapDeposit_endToEnd_succeeds` |
| Sponsorship within budget accepted | `test_bootstrapSponsorship_withinBudget_accepted` |
| `maxCost` above `B_boot` rejected | `test_bootstrapSponsorship_maxCostExceedsBudget_rejected` |
| `maxFeePerGas` above `p_max` rejected | `test_bootstrapSponsorship_gasPriceExceedsCap_rejected` |
| `execute()` to a target other than the pool rejected | `test_bootstrapDeposit_executeToOtherTarget_rejected` |
| `execute()` carrying ETH rejected | `test_bootstrapDeposit_executeWithValue_rejected` |
| `execute()` calling a pool function other than `deposit` rejected | `test_bootstrapDeposit_executeWrongPoolFunction_rejected` |

ERC-4337 executes `callData` on `userOp.sender`, so a Bootstrap operation is an account
execution wrapping the pool call. `BootstrapPaymaster` pins every field of that wrapper —
`execute` selector, target, zero value, canonical bytes offset, inner length, inner
`deposit(uint256)` selector — leaving only the commitment argument free. Trace evidence from the
end-to-end test:

```
emit BootstrapSponsored(stealthAddress: ERC1967Proxy…)
SimpleAccount::execute
  CreditPool::deposit(42424242)
    CreditPaymaster::mirrorRoot(42424242)
      emit RootMirrored(newRoot: 42424242)
    emit Deposited(commitment: 42424242, newRoot: 42424242)
success: true      actualGasUsed: 223579
```

The wrong-pool-function case uses `mirrorEligible(address)`, which encodes to the *same* 36-byte
inner shape as `deposit(uint256)`, so only the inner-selector check can reject it.

---

## 5. Gas (paper Table II)

See `GAS_REPORT.md` for the full methodology, distributions, and end-to-end `handleOps` costs.
Headline figures (full-suite maxima, `forge test --gas-report`):

| Operation | Gas (max) | Measurement type |
|---|---|---|
| `announceAndFund()` | 175,951 | Foundry gas report |
| Bootstrap validation | 52,543 | Foundry gas report, direct call |
| `CreditPool.deposit()` | 216,905 | Foundry gas report |
| Credit validation | 284,527 | Foundry gas report, direct call, real verifier |
| Groth16 verification (isolated) | 225,733 | Measured verifier call |

Two caveats a reader reproducing Table II needs, both documented in `GAS_REPORT.md`:

1. `announceAndFund()` and `CreditPool.deposit()` are population-dependent — restricting the run
   to a subset of suites lowers them to 175,795 and 192,506. The values above are the full-suite
   maxima that a plain `forge test --gas-report` produces.
2. The two validation rows are **direct-call** measurements. `forge --gas-report` does not
   attribute paymaster calls dispatched by the EntryPoint's inline-assembly `call`, so these are
   maxima over `vm.prank(entryPoint)` unit-test calls. The corresponding frame costs inside
   `handleOps` are lower — 27,031 (Bootstrap) and 251,403 (Credit) — so the reported figures are
   conservative upper bounds, which is the safe direction for the 500,000-gas limit claim.

---

## 6. What this artifact does not establish

Stated explicitly so reviewers do not over-read the results.

- **No bundler-level ERC-7562 opcode tracing.** `SimulateValidationTest` confirms both
  paymasters pass the real EntryPoint validation dispatch reading only their own storage, and
  that both are staked. It does not trace opcodes. Forbidden-opcode compliance is argued by code
  review, not verified mechanically.
- **No deployment.** No mainnet or public-testnet run; no live bundler.
- **No security audit.**
- **Anonymity is not measured.** The evaluation group has 4 members. The artifact demonstrates
  proof-level commitment-index privacy by construction; it does not quantify anonymity-set size,
  timing correlation, or cold-start exposure.
- **No root history.** `CreditPaymaster` accepts only the latest mirrored root, so a concurrent
  deposit invalidates outstanding proofs. This is a liveness property the paper discloses; it is
  demonstrated, not fixed, by `test_unacceptedMerkleRoot_rejected`.
- **Stealth-address derivation is out of scope.** The paper models the stealth account as a
  counterfactual CREATE2 account derived from an ERC-5564 announcement. The artifact uses a
  standard `SimpleAccount` as the ERC-4337 sender and implements neither ERC-5564 key derivation
  nor the factory `initCode` deployment path. `MockAnnouncer` stands in for the canonical
  Announcer, whose only role is emitting the announcement event.
- **`postOp` is unused.** Both paymasters return empty context, so the post-operation hook is
  never exercised.

---

## 7. Reproduction

```bash
git clone <repo> && cd stealth-protocol

forge test                                                   # 65 passing, offline
forge test --gas-report                                      # gas table
forge test --match-contract FunctionalCorrectnessTest -vv    # six Spend cases
forge test --match-contract BootstrapSponsorshipBoundTest -vv
forge test --match-contract RealGroth16Test -vv              # 225,733
forge script script/Demo.s.sol:Demo -vv                      # three-stage walkthrough
```

All Solidity dependencies are vendored; no network access is required. Regenerating the ZK proof
fixtures does require Node and network — see `script/proof/README.md`. Dependency versions and
subtree checksums are in `DEPENDENCIES.md`.
