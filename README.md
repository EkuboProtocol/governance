# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Simple-as contracts for token governance on Starknet.

## Principles

These contracts follow the Compound governance architecture.
Contracts are focused on immutability, so it's broken up into a set of very modular components.

All contracts are intended to be upgraded by simply migrating to new ones. Even the token contract can be migrated, if necessary, by deploying a new contract that allows burning the old token to mint the new one. It's likely volition will make voting use cases significantly cheaper, given the amount of indexed data required by the token contract, so upgrades of this sort are to be expected.

The structure is as follows:

- `Timelock` is an owned contract that allows a list of calls to be queued by an owner
    - Anyone can execute the calls after a period of time, once queued by the owner
    - Timelock is meant to own all assets, and rarely be upgraded
    - In order to upgrade timelock, all assets must be transferred to a new timelock
- `Governor` manages voting on a _single call_ that can be queued into a timelock
    - Designed to be the owner of Timelock
    - The single call can be to `Timelock#queue(calls)`, which can execute multiple calls in a single proposal
    - Timelock ownership may be transferred to a new governance contract in future, e.g. to migrate to a volition-based voting contract
    - None of the proposal metadata is stored in governor, simply the number of votes
    - Proposals can be canceled at any time if the voting weight of the proposer falls below the threshold
- `Token` is an ERC20 token meant for voting in contracts like `Governor`
    - Users must delegate their tokens to vote, and may delegate to themselves
    - Allows other contracts to get the average voting weight for *any* historical period
    - Average votes are used to compute voting weight in the `Governor`, over a configurable period of time
- `Airdrop` can be used to distribute Token
    - Compute a merkle root by computing a list of amounts and recipients, hashing them, and arranging them into a merkle binary tree
    - Deploy the airdrop with the root and the token address
    - Transfer the total amount of tokens to the `Airdrop` contract

## Testing

This code uses the version of Scarb specified in [.github/workflows/test.yaml](./.github/workflows/test.yaml). To run unit tests, simply run:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.

## Credits

The [Airdrop](./src/airdrop.cairo) contract was heavily inspired by the [Carmine Options Airdrop contract](https://github.com/CarmineOptions/governance/blob/master/src/airdrop.cairo).
