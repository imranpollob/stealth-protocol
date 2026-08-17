# Gas Measurements — PrivGas

Environment: Foundry `1.4.1-stable`, Solidity `0.8.28`, optimizer on (200 runs), `via_ir = true`,
local Foundry EVM. Regenerate everything below with:

```bash
forge test --gas-report
forge test --match-contract RealGroth16Test -vv        # isolated Groth16 figure
forge test --match-test test_validProof_unspentNullifier_correctSender_accepted -vvvv
forge test --match-test test_bootstrapDeposit_endToEnd_succeeds -vvvv
```

---

## 1. Evaluation table (paper Table II)

Function-level maxima from `forge test --gas-report` over the **complete 65-test suite**.

| Operation | Gas (max) | Measurement type |
|---|---|---|
| `announceAndFund()` | **175,951** | Foundry gas report |
| Bootstrap validation (`validatePaymasterUserOp`) | **52,543** | Foundry gas report, direct call |
| `CreditPool.deposit()` | **216,905** | Foundry gas report |
| Credit validation (`validatePaymasterUserOp`) | **284,527** | Foundry gas report, direct call, real verifier |
| Groth16 verification (`SemaphoreVerifier.verifyProof`) | **225,733** | Measured verifier call |

Credit validation at 284,527 gas is **43.1 % below** the 500,000-gas ERC-4337 verification
limit.

### The two validation rows are direct-call measurements, not EntryPoint-dispatched

`forge --gas-report` does **not** attribute paymaster calls made by the EntryPoint. The
EntryPoint invokes `validatePaymasterUserOp` through an inline-assembly `call` in
`_callValidatePaymasterUserOp`, and those frames never appear in the report. Verified:

```bash
forge test --gas-report --match-contract FunctionalCorrectnessTest    # no validatePaymasterUserOp row
forge test --gas-report --match-contract BootstrapSponsorshipBoundTest # no validatePaymasterUserOp row
```

Both suites run exclusively through `handleOps`, and both contribute zero counted calls; the
counts stay at 10 (Bootstrap) and 23 (Credit) whether or not they are included in the run.

So the two figures above are maxima over the **direct** `vm.prank(entryPoint)` unit-test calls.
The corresponding costs *inside* `handleOps`, read from execution traces, are lower:

| Paymaster | Gas-report max (direct call) | Frame cost inside `handleOps` |
|---|---|---|
| `BootstrapPaymaster.validatePaymasterUserOp` | 52,543 | **27,031** |
| `CreditPaymaster.validatePaymasterUserOp` | 284,527 | **251,403** |

The gap is caller-side overhead: a direct call pays calldata and memory-expansion cost for the
fully ABI-encoded `PackedUserOperation` (the `paymasterAndData` region alone carries a 416-byte
proof), which the trace frame does not include.

Both reported figures are therefore **conservative upper bounds** on the real in-EntryPoint
cost, which is the safe direction for the "below the 500,000-gas limit" claim.

### Measurement-population caveat

Two of these figures depend on which suites are in the run, because `--gas-report` reports
maxima over all observed calls:

| Operation | Full suite | Excluding `FunctionalCorrectnessTest` and `BootstrapSponsorshipBoundTest` |
|---|---|---|
| `announceAndFund()` | 175,951 | 175,795 |
| `CreditPool.deposit()` | **216,905** | 192,506 |
| Bootstrap validation | 52,543 | 52,543 |
| Credit validation | 284,527 | 284,527 |

The table above reports the **full-suite** maxima, so a plain `forge test --gas-report`
reproduces it exactly.

`CreditPool.deposit()` differs most (216,905 vs 192,506) for a real reason, not noise: the
functional-correctness fixture builds a 4-leaf tree, and inserting into a deeper LeanIMT costs
more Poseidon hashing than the first insertion into an empty tree. 216,905 is the true
worst case observed and is the defensible number to report.

---

## 2. Full distributions (`forge test --gas-report`, complete suite)

### `AnnouncementRegistry.announceAndFund()`
| Min | Avg | Median | Max | Calls |
|---|---|---|---|---|
| 27,202 | 146,514 | 150,862 | **175,951** | 78 |

Min is a revert path (below `vMin + F`). Max is the cold happy path: fee routed to the sink + ETH forward +
`announce()` + two `mirrorEligible()` writes.

### `BootstrapPaymaster.validatePaymasterUserOp()`
| Min | Avg | Median | Max | Calls |
|---|---|---|---|---|
| 29,698 | 41,865 | 42,306 | **52,543** | 10 |

Max is the cold first call: budget check, gas-price check, six calldata call-shape checks,
eligibility read, and the `_used` write.

### `CreditPool.deposit()`
| Min | Avg | Median | Max | Calls |
|---|---|---|---|---|
| 26,056 | 158,956 | 143,339 | **216,905** | 58 |

Min is a revert path (ineligible). Max is an insertion into a populated LeanIMT plus the
`mirrorRoot()` push into `CreditPaymaster`.

### `CreditPaymaster.validatePaymasterUserOp()`
| Min | Avg | Median | Max | Calls |
|---|---|---|---|---|
| 35,360 | 59,176 | 44,690 | **284,527** | 23 |

Max is the full accept path with the **real** `SemaphoreVerifier`. Lower values are early
rejections (budget, root, digest, nullifier) and mock-verifier unit tests, which return before
or without the BN254 pairing.

### `SemaphoreVerifier.verifyProof()` — real BN254 Groth16
| Tree depth | Gas |
|---|---|
| 1 | **225,733** |
| 16 | 225,732 |

`gasleft()` delta around the call, from `test/RealGroth16.t.sol`. Cost is independent of tree
depth: the verifying key differs per depth but the pairing check does not.

---

## 3. End-to-end `handleOps` costs

Whole-operation costs through the real EntryPoint, which is what a bundler actually pays.

### Spend (`test_validProof_unspentNullifier_correctSender_accepted`)
| Frame | Gas |
|---|---|
| `EntryPoint::handleOps` (entire call) | 371,191 |
| EntryPoint-accounted `actualGasUsed` (`UserOperationEvent`) | **354,745** |
| `CreditPaymaster::validatePaymasterUserOp` | 251,403 |
| ↳ `SemaphoreVerifier::verifyProof` (depth 2) | 219,064 |
| `SimpleAccount::validateUserOp` (ECDSA, warm) | 6,608 |
| sponsored target call | 22,256 |
| EntryPoint `maxCost` (requiredPrefund) at 1 gwei | 721,000 wei-gas → 7.21 × 10¹⁴ wei |

### Bootstrap (`test_bootstrapDeposit_endToEnd_succeeds`)
| Frame | Gas |
|---|---|
| EntryPoint-accounted `actualGasUsed` | **223,579** |
| EntryPoint `maxCost` (requiredPrefund) at 1 gwei | 421,000 wei-gas → 4.21 × 10¹⁴ wei |

`verifyProof` measures 219,064 inside `handleOps` versus 225,733 in isolation. This is a
measurement-point difference — call-frame accounting versus a `gasleft()` delta with cold
memory — not a behavioural one.

---

## 4. Relation to the economic bound

Both paymasters cap the EntryPoint's `maxCost` at 0.005 ETH and `maxFeePerGas` at 10 gwei, so
worst-case exposure per credit is bounded **independently of the measurements above**:

```
c_credit · p_max  ≤  B_boot + B_spend  =  0.005 + 0.005  =  0.010 ETH
κ · (B_boot + B_spend)                 =  2 × 0.010      =  0.020 ETH
F                                      =  0.021 ETH      >  0.020 ETH   ✓
```

The measured operations sit well inside those caps — Spend costs 3.55 × 10⁻⁴ ETH and Bootstrap
2.24 × 10⁻⁴ ETH at 1 gwei — so the bound binds on the enforced ceiling, not on typical cost.

---

## 5. Deployment costs

| Contract | Deployment gas | Runtime size (bytes) |
|---|---|---|
| `AnnouncementRegistry` | 544,085 | 2,479 |
| `BootstrapPaymaster` | 428,024 | 2,107 |
| `CreditPaymaster` | 657,890 | 3,116 |
| `CreditPool` | 390,230 | 1,803 |

`CreditPool` embeds `PoseidonT3` via `InternalLeanIMT`. Values are from the same
`--gas-report` run; re-measure after any source change.
