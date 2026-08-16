# Semaphore Proof Fixture

`test/fixtures/semaphore-valid-proof-depth1.json` is a precomputed Semaphore v4 proof for:

- `commitment`: `4684165875510583658938432194899771179479177047942766898741235713884416730890`
- `message`: `0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`
- `scope`: `keccak256("stealth-protocol.credit.v1")`
- `merkleTreeDepth`: `1`

The public signals passed to `SemaphoreVerifier.verifyProof` are:

1. `merkleTreeRoot`
2. `nullifier`
3. `keccak256(abi.encodePacked(message)) >> 8`
4. `keccak256(abi.encodePacked(scope)) >> 8`

Regenerate from the repo root:

```bash
mkdir -p /tmp/stealth-semaphore-proof
npm --prefix /tmp/stealth-semaphore-proof init -y
npm --prefix /tmp/stealth-semaphore-proof install @semaphore-protocol/core@4.14.2
SEMAPHORE_CORE_PATH=/tmp/stealth-semaphore-proof/node_modules/@semaphore-protocol/core/src/index.js \
  node script/proof/generateSemaphoreFixture.mjs
```

---

# Functional-Correctness Fixtures (paper table)

`test/FunctionalCorrectness.t.sol` backs the six-row functional-correctness table. Its proofs
are bound to hashes the EntryPoint actually computes, so they cannot be generated standalone —
the operation hash is a keccak preimage that no prover can invert. The fixtures are therefore
produced in three phases.

**Phase 1 — emit the EntryPoint-computed operation hashes.**

```bash
forge script script/proof/DumpUserOpHashes.s.sol:DumpUserOpHashes
# -> test/fixtures/functional-correctness-ops.json
```

**Phase 2 — generate genuine Groth16 proofs over those hashes.**

```bash
SEMAPHORE_CORE_PATH=/tmp/stealth-semaphore-proof/node_modules/@semaphore-protocol/core/src/index.js \
  node script/proof/generateFunctionalCorrectnessProofs.mjs
# -> test/fixtures/functional-correctness-proofs.json
```

Four deterministic identities form a Semaphore group (`merkleTreeDepth` 2); leaf index 1
spends. Three proofs are produced — for `opAccept`, `opSecond` and `opOverBudget` — each
checked with `verifyProof` before being written. The scope is fixed, so all three reveal the
same nullifier, which is what makes the spent-nullifier row a genuine double-spend of one
credit rather than two unrelated proofs.

**Phase 3 — run the tests.**

```bash
forge test --match-contract FunctionalCorrectnessTest -vv
```

Phase 1 and phase 3 both inherit `test/FunctionalCorrectnessFixture.sol`, so the deployment
(and hence every address feeding the EIP-712 operation hash) is identical. Each test asserts
`entryPoint.getUserOpHash(op) == proof.message` before submitting; if anything drifts, the
tests fail rather than degrading into a check against an arbitrary literal.

This works because the proof travels in the ERC-4337 v0.9 paymaster-signature region
(`… || proof || uint16(len) || PAYMASTER_SIG_MAGIC`), which `paymasterDataKeccak` excludes
from the operation hash — asserted directly by
`test_operationHashIsIndependentOfProofBytes`.
