# Dependencies and Provenance

PrivGas vendors the exact Solidity sources it compiles, under `lib/`. A fresh clone
builds and runs the full test suite **offline** — no `forge install`, no npm, no network.

```bash
git clone <repo> && cd stealth-protocol
forge test          # 65 passing, no network access required
```

## Why the sources are vendored

`lib/account-abstraction` is a **pre-release v0.9 development snapshot**. At the time of
writing, npm publishes `@account-abstraction/contracts` only up to `0.8.0` (latest) and
`0.9.0-rc.1` (rc); the tree used here self-reports `0.9.0` and contains v0.9-only
machinery that the published releases do not:

- `PAYMASTER_SIG_MAGIC` / `getPaymasterSignature()` in `UserOperationLib.sol`
- `bytes32 transient currentUserOpHash` in `EntryPoint.sol`
- the EIP-712 `("ERC4337","1")` `userOpHash` domain

The whole proof-binding construction depends on that first item, so pinning by published
version number would not reproduce the measured system. Vendoring the sources is what makes
the reported gas figures and the functional-correctness results independently checkable.

## Vendored subtrees

Only the directories the build actually compiles are committed (~5 MB), together with each
dependency's `LICENSE` and `package.json` for provenance. Unused monorepo content
(test suites, JS packages, docs) is not included.

| Dependency | Version | Vendored path | Files | SHA-256 of subtree |
|---|---|---|---|---|
| `account-abstraction` (eth-infinitism) | `0.9.0` (pre-release snapshot) | `lib/account-abstraction/contracts` | 59 | `9e4a17200044025d4ab8d39371b4dee218de2187aaa647ab074cebd1a16e2e6c` |
| `forge-std` | `1.16.1` | `lib/forge-std/src` | 31 | `816d2adb106cb7e5c3016f741b8c236e158369d06ebce25d81e838227b851a52` |
| `openzeppelin-contracts` | `5.6.1` | `lib/openzeppelin-contracts/contracts` | 378 | `f29b971fe3c63eed2ad96982175f712935632e779768316aa5eb269fb7139b8f` |
| `semaphore-contracts` (Semaphore v4) | v4 contracts | `lib/semaphore/packages/contracts/contracts` | 11 | `4f46cd4913605ec91bdd075f737bc807d631626ab7d6d770d1b57390ada9d106` |
| `@zk-kit/lean-imt.sol` | `2.0.1` | `lib/zk-kit.solidity/packages/lean-imt/contracts` | 7 | `0a994ed7b5f80f725ca1bb6d73e14c8291b776b277025289beb03363439cdd91` |
| `poseidon-solidity` | `0.0.5` | `lib/poseidon-solidity` | 14 | `2f0cd0a7c9bf3882164c2590b973e90683f5ffb679ff67b65ff8cef6ad451663` |

Recompute any row with:

```bash
find <path> -type f -exec sha256sum {} \; | sort -k2 | sha256sum
```

## Import remappings

`remappings.txt` maps each import prefix onto the vendored path:

```
forge-std/=lib/forge-std/src/
account-abstraction/=lib/account-abstraction/contracts/
@semaphore-protocol/contracts/=lib/semaphore/packages/contracts/contracts/
@zk-kit/lean-imt.sol/=lib/zk-kit.solidity/packages/lean-imt/contracts/
poseidon-solidity/=lib/poseidon-solidity/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
```

## Toolchain

| Component | Version |
|---|---|
| Foundry (`forge`) | `1.4.1-stable` (commit `cf77460`) |
| Solidity | `0.8.28` (pinned in `foundry.toml`) |
| Optimizer | enabled, 200 runs, `via_ir = true` |
| Node.js | v22.20.0 — **only** for regenerating ZK proof fixtures |

Node is not needed to build or test. Committed fixtures under `test/fixtures/` are
sufficient; Node and network access are required only to regenerate them
(see `script/proof/README.md`).

## Off-chain proving dependency (fixture regeneration only)

| Package | Version | Purpose |
|---|---|---|
| `@semaphore-protocol/core` | `4.14.2` | identity, group, and `groth16.fullProve` proof generation |

Semaphore's trusted-setup artifacts (`semaphore-2.wasm`, `semaphore-2.zkey`) are fetched at
generation time from `snark-artifacts.pse.dev`. They are not vendored, and are not needed to
verify the committed proofs — on-chain verification uses the vendored `SemaphoreVerifier.sol`.
