import { writeFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

const corePath = process.env.SEMAPHORE_CORE_PATH ?? "@semaphore-protocol/core"
const coreModule = corePath.startsWith("/") ? pathToFileURL(corePath).href : corePath
const { Identity, Group, generateProof, verifyProof } = await import(coreModule)

const privateKey = "stealth-protocol-real-proof-fixture-v1"
const message = BigInt("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
const scope = BigInt("0xda64d6ca7f2d50dccb676186338da42004b36a7f76c3bc6d5f6f08291a093979")

const identity = new Identity(privateKey)
const group = new Group([identity.commitment])
const proof = await generateProof(identity, group, message, scope, 1)
const verified = await verifyProof(proof)

const fixture = {
  privateKey,
  commitment: identity.commitment.toString(),
  groupRoot: group.root.toString(),
  message: message.toString(),
  scope: scope.toString(),
  proof,
  verified,
  publicSignals: {
    merkleTreeRoot: proof.merkleTreeRoot,
    nullifier: proof.nullifier,
    message: proof.message,
    scope: proof.scope
  }
}

writeFileSync("test/fixtures/semaphore-valid-proof-depth1.json", `${JSON.stringify(fixture, null, 2)}\n`)
console.log(JSON.stringify(fixture, null, 2))
