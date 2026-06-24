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
