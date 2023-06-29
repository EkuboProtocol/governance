# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Simple-as contracts for token governance on Starknet.

## Principles

Contracts follow the Compound governance architecture.
Contracts are focused on immutability.
All contracts are intended to be upgraded by simply migrating to new ones. Even the token contract can be migrated, if necessary.

The structure is as follows:

- Timelock is an owned contract that allows a list of calls to be queued by an owner
    - Anyone can execute the calls after a period of time, once queued by the owner
    - Timelock is meant to own all assets, and never be upgraded
- Governor manages voting on a single call that can be queued into a timelock
    - Meant to own the timelock contract
    - The single call can be to Timelock#queue, which can execute multiple calls in a single proposal
    - Timelock may be transferred to a new governance contract in future, e.g. to migrate to a volition-based contract
    - None of the proposal metadata is stored in governor, simply the number of votes
    - Proposals can be canceled at any time
- Token represents the voting right
    - Keeps track of average votes over any period of time
    - Average votes are used to compute voting weight
- Airdrop can be used to distribute Token
    - Compute a merkle root by computing a list of amounts and recipients, hashing them, and arranging them into a merkle binary tree

## Testing

This code uses the version of Scarb specified in [.github/workflows/test.yaml](./.github/workflows/test.yaml). To run unit tests, simply run:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.

## Credits

The [Airdrop](./src/airdrop.cairo) contract was heavily inspired by the [Carmine Options Airdrop contract](https://github.com/CarmineOptions/governance/blob/master/src/airdrop.cairo).
