# Gas Measurements — Stealth Protocol

Measured on local Anvil (Solc 0.8.28, optimizer 200 runs, via-IR).
All numbers are **function-level gas units** from `forge test --gas-report`.
Test-level numbers (which include test harness overhead) are noted separately.

---

## Evaluation Table (for paper)

| Operation | Gas units | Notes |
|-----------|-----------|-------|
| `announceAndFund()` (AnnouncementRegistry) | **116,577** | max; includes ETH forward + Announcer.announce() + 2× mirrorEligible() |
| Bootstrap-sponsored `deposit()` total | **~194,000** | validatePaymasterUserOp (51,121) + CreditPool.deposit (143,002) |
| Credit-sponsored spend — `validatePaymasterUserOp` (CreditPaymaster) | **62,535** | max; includes ZK proof decode + root check + nullifier check + verifyProof() |

---

## Detailed Breakdown (from `forge test --gas-report`)

### AnnouncementRegistry.announceAndFund()
| Min | Avg | Median | Max | Calls |
|-----|-----|--------|-----|-------|
| 25,052 | 104,654 | 116,182 | 116,577 | 32 |

*Min is from revert cases (sub-vMin). Happy-path max = 116,577.*

### BootstrapPaymaster.validatePaymasterUserOp()
| Min | Avg | Median | Max | Calls |
|-----|-----|--------|-----|-------|
| 29,554 | 39,232 | 30,070 | 51,121 | 9 |

*Max = first-call cost with cold storage (eligible set, used=false → true).*

### CreditPool.deposit()
| Min | Avg | Median | Max | Calls |
|-----|-----|--------|-----|-------|
| 26,056 | 131,016 | 143,002 | 192,481 | 21 |

*Max = first insertion into the Lean IMT (cold Poseidon tree storage).*

### CreditPaymaster.validatePaymasterUserOp()
| Min | Avg | Median | Max | Calls |
|-----|-----|--------|-----|-------|
| 34,160 | 49,647 | 62,295 | 62,535 | 15 |

*This is the ZK proof verification cost (mock verifier = pure returns(bool) — the real*
*Groth16 verifier adds ~200,000–300,000 gas for the pairing check on top of this).*

---

## Note on Proof Verification Cost

The test suite uses a `MockSemaphoreVerifier` that returns `true` without computation.
The real `SemaphoreVerifier` (Groth16 pairing over BN254) costs approximately **200,000–300,000
gas** for `verifyProof()`. Add this to the CreditPaymaster row for real-world figures.

Updated estimate for credit-sponsored spend with real verifier: **~260,000–360,000 gas**
(34,160 base overhead + 62,535 max paymaster logic + ~200,000 real Groth16 cost).

---

## Reproduce

```bash
# All tests (39/39)
forge test -vv

# Gas report
forge test --gas-report

# Gas snapshot
forge snapshot

# Demo (3-step protocol flow)
forge script script/Demo.s.sol:Demo -vv
```
