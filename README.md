# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Simple contracts for governance on Starknet.

## Components

Each component of the governance contracts in this repository may be used independently.

### ERC20

`GovernanceToken` is an ERC20 that tracks delegations as well as time-weighted average delegations for any period

- Users MAY delegate their tokens to other addresses
- The average historical delegation weight is computable over *any* historical period
- The contract has no owner and is not upgradeable.

### Airdrop

`Airdrop` can be used to distribute any fungible token, including the `GovernanceToken`. To use it, you must compute a binary merkle tree using the pedersen hash function. The root of this tree and the token address are passed as constructor arguments.

- Compute a merkle root by computing a list of amounts and recipients, hashing them, and arranging them into a merkle binary tree
- Deploy the airdrop with the root and the token address
- Transfer the total amount of tokens to the `Airdrop` contract
- The contract has no owner and is not upgradeable. Unclaimed tokens, by design, cannot be recovered.

### Timelock

`Timelock` allows a list of calls to be executed, after a configurable delay, by its owner

- Anyone can execute the calls after a period of time, once queued by the owner
- Designed to be the owner of all the assets held by a DAO
- Must re-configure, change ownership, or upgrade itself via a call queued to itself

### Governor

`Governor` allows `GovernanceToken` holders to vote on whether to make a _single call_
- The single call can be to `Timelock#queue(calls)`, which can execute multiple calls in a single proposal
- None of the proposal metadata is stored in governor, simply the number of votes
- Proposals can be canceled at any time if the voting weight of the proposer falls below the configurable threshold

### Factory

`Factory` allows creating the entire set of contracts with a single call.

## Testing

Make sure you have [Scarb with asdf](https://docs.swmansion.com/scarb/download#install-via-asdf) installed.

To run unit tests:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.
