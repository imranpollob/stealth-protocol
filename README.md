# PrivGas — Research Artifact

Reference implementation and evaluation harness for:

> **PrivGas: A Privacy-Preserving Gas Sponsorship Protocol for Blockchain Stealth Addresses**
> M M Imran, Anik Tahabilder, Changxin Bai, Qiang Zhu, Shiyong Lu

PrivGas is a three-stage ERC-4337 gas-sponsorship protocol (Fund → Bootstrap → Spend) that
lets an ERC-5564 stealth account pay for its first outbound transaction without a
recipient-side gas top-up from a known wallet. A non-refundable fee gates admission, a
Semaphore v4 shielded credit pool holds commitments, and redemption is authorised by a
Groth16 membership proof bound to the operation hash.

## Quick start

Requires only [Foundry](https://book.getfoundry.sh/getting-started/installation).
All Solidity dependencies are vendored — **no network access is needed**.

```bash
git clone <repo> && cd stealth-protocol
forge test              # 65 passing
```

To reproduce the gas table:

```bash
forge test --gas-report
```

## Layout

```
src/
  AnnouncementRegistry.sol   Stage 1 (Fund) — payable ERC-5564 wrapper; routes the non-refundable
                             fee F to a non-recoverable sink, forwards >= V_min to the stealth
                             address, mirrors eligibility, enforces the minimum admissible F
  BootstrapPaymaster.sol     Stage 2 (Bootstrap) — sponsors exactly one credit deposit per
                             eligible address, bounded by B_boot and p_max
  CreditPool.sol             Shielded Credit Pool — LeanIMT of Semaphore v4 commitments C
  CreditPaymaster.sol        Stage 3 (Spend) — sponsors any operation against a Groth16
                             membership proof, bounded by B_spend and p_max
  AcceptAllPaymaster.sol     Unconditional paymaster, used only as a gas baseline
  lib/                       EligibilityLogic (call-shape + admission policy), NullifierLogic
  interfaces/

test/
  FunctionalCorrectness.t.sol        The six Spend-phase cases in the paper's correctness table
  FunctionalCorrectnessFixture.sol   Deterministic deployment shared with the fixture generator
  BootstrapSponsorshipBound.t.sol    Bootstrap budget, gas-price cap, and end-to-end deposit
  fixtures/                          Genuine Groth16 proofs + the operation hashes they bind to
  ...                                Unit suites per contract

script/
  Demo.s.sol                         Three-stage walkthrough
  proof/                             Three-phase ZK fixture pipeline (see script/proof/README.md)
```

## Reproducing the paper's claims

| Paper claim | Command | Where |
|---|---|---|
| 65 passing tests | `forge test` | whole suite |
| **Table III** — functional correctness, 6 Spend cases | `forge test --match-contract FunctionalCorrectnessTest -vv` | `test/FunctionalCorrectness.t.sol` |
| **Table II** — gas evaluation | `forge test --gas-report` | see `GAS_REPORT.md` |
| Isolated Groth16 verification (225,733) | `forge test --match-contract RealGroth16Test -vv` | `test/RealGroth16.t.sol` |
| Bootstrap sponsorship bound + end-to-end deposit | `forge test --match-contract BootstrapSponsorshipBoundTest -vv` | `test/BootstrapSponsorshipBound.t.sol` |
| **Eq. (1)** / G1 — Sybil-resistance economics | `forge test --match-contract SybilResistanceTest` | `test/SybilResistance.t.sol` |
| G3 — one-credit redemption | `forge test --match-contract ReplayResistanceTest` | `test/ReplayResistance.t.sol` |
| ERC-7562 validation-scope check | `forge test --match-contract SimulateValidationTest -vv` | `test/SimulateValidation.t.sol` |
| Three-stage flow walkthrough | `forge script script/Demo.s.sol:Demo -vv` | `script/Demo.s.sol` |

`GAS_REPORT.md` gives the full measurement methodology and every figure in the paper's gas
table. `PAPER_SUPPLEMENT.md` maps each paper claim to the specific test that substantiates it,
and states the claims the artifact does **not** cover.

## How the evaluation is grounded

The six Spend-phase cases are full ERC-4337 integration tests, not unit stubs. Each runs
through the real `EntryPoint.handleOps` (account-abstraction v0.9) with:

- a real `SimpleAccount` sender validating an ECDSA signature,
- the real Semaphore `SemaphoreVerifier` performing BN254 Groth16 verification on-chain,
- genuine `snarkjs groth16.fullProve` proofs over a 4-member group (`merkleTreeDepth` 2),
- `maxCost` and `userOpHash` computed by the EntryPoint, never supplied as literals.

A proof cannot be generated for an operation hash without first knowing that hash, and the
hash cannot be inverted. Fixtures are therefore produced in three phases — dump the
EntryPoint-computed hashes, prove over them, then replay the identical deployment. Every test
asserts `entryPoint.getUserOpHash(op) == proof.message` before submitting, so any drift fails
loudly instead of silently degrading into a check against an arbitrary value. See
`script/proof/README.md`.

`MockSemaphoreVerifier` and `MockAccount` exist for the unit suites and are **not** used by
any paper-table test. `MockAnnouncer` is used throughout: it is a stand-in for the canonical
ERC-5564 Announcer, whose only role is emitting an event, and it is not on the path of any
asserted property.

## Economic configuration (paper Eq. (1))

Both paymasters bound what one credit can cost the protocol:

| Parameter | Value | Enforced by |
|---|---|---|
| `B_boot` — Bootstrap sponsorship cap | 0.005 ETH | `BootstrapPaymaster.MAX_BOOTSTRAP_SPONSORSHIP_COST` |
| `B_spend` — Spend sponsorship cap | 0.005 ETH | `CreditPaymaster.MAX_SPONSORSHIP_COST` |
| `p_max` — maximum gas price | 10 gwei | `MAX_ACCEPTED_MAX_FEE_PER_GAS` (both) |
| `F` — non-refundable fee | 0.021 ETH | `AnnouncementRegistry`, configured |
| minimum admissible `F` | > 0.020 ETH | `AnnouncementRegistry.MIN_NON_REFUNDABLE_FEE` |

Both caps are checked against the EntryPoint's own `maxCost` (its `requiredPrefund`), not
against gas-field proxies — `requiredPrefund` covers all five gas terms, so a per-field cap
would leave the account's attacker-controlled verification phase unbounded.

Giving `F > κ·(B_boot + B_spend)` with κ = 2: `0.021 > 2 × (0.005 + 0.005) = 0.020` ✓

`MIN_NON_REFUNDABLE_FEE` rejects the boundary at both deployment and update, so a
configuration violating the bound cannot be installed.

## Scope and limitations

- **Prototype, not audited.** No mainnet or public-testnet deployment.
- **ERC-7562 checked by simulation, not by a bundler.** `SimulateValidationTest` runs
  `EntryPointSimulations.simulateValidation` and confirms both paymasters pass the real
  validation dispatch reading only their own storage. It does **not** perform opcode tracing;
  forbidden-opcode compliance is argued by code review.
- **Single Merkle root.** `CreditPaymaster` accepts only the latest mirrored root; there is no
  root history or window, so a new deposit invalidates outstanding proofs.
- **Anonymity set.** The evaluation group has 4 members. Real deployments need a populated
  pool; cold-start and timing correlation are discussed as future work in the paper.
- **Stealth account derivation is out of scope here.** The paper models the stealth account as
  a counterfactual CREATE2 account; the artifact uses a standard `SimpleAccount` as the
  ERC-4337 sender and does not implement ERC-5564 key derivation or a factory `initCode` path.

## License

MIT — see `LICENSE`. Vendored dependencies keep their own licenses; see `DEPENDENCIES.md`.
