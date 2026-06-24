# Stealth Protocol

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) (for `npm pack`)

## Setup

```bash
# Initialize project
forge init --no-git --force

# Install dependencies
forge install semaphore-protocol/semaphore --no-git
forge install eth-infinitism/account-abstraction --no-git
forge install privacy-scaling-explorations/zk-kit.solidity --no-git

# Install poseidon-solidity
npm pack poseidon-solidity@0.0.5
mkdir -p lib/poseidon-solidity
tar -xzf poseidon-solidity-0.0.5.tgz -C /tmp/ && cp -r /tmp/package/* lib/poseidon-solidity/
```

## Usage

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

### Gas Snapshots

```bash
forge snapshot
```

### Anvil

```bash
anvil
```

### Deploy

```bash
forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```bash
cast <subcommand>
```

### Help

```bash
forge --help
anvil --help
cast --help
```
