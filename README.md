# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Simple contracts for governance on Starknet.

## Components

Each component of the governance contracts in this repository may be used independently.

### Distribution

#### Airdrop

`Airdrop` is a highly-optimized distribution contract for distributing a fungible ERC20-like token to many (`O(1e6)`) accounts. To use it, you must compute a binary merkle tree using the pedersen hash function of an `id`-sorted list of `Claim` structs. The root of this tree and the token address are passed as constructor arguments and cannot change.

- Compute a merkle root by producing a list of `Claim` structs, hashing them, sorting by sequentially-assigned ID, and arranging them into a merkle binary tree
  - Claim IDs must be sorted, start from `0` and be contiguous to make optimal use of the contract's `claim_128` entrypoint
- Deploy the airdrop with the `root` from this merkle tree and the token address
- Transfer the total amount of tokens to the `Airdrop` contract
- Unclaimed tokens can be refunded to the specified `refund_to` address after the `refundable_timestamp`, _iff_ `refundable_timestamp` is not zero

### Governance

#### Staker

`Staker` enables users to delegate the balance of their token towards an account, and tracks the historical delegation at each block, plus allows the computation of the time-weighted average delegation of any account over any historical period.

- Users call `Token#approve(staker, stake_amount)`, then `Staker#stake(delegate)` to stake and delegate their tokens to other addresses
- Users call `Staker#withdraw(delegate, recipient, amount)` to remove part or all of their delegation
- The average historical delegation weight is computable over *any* historical period
- The contract has no owner, and cannot be updated nor configured.

#### Governor

`Governor` allows  holders to vote on whether to make a _single call_

- None of the proposal metadata is stored in governor, simply the number of votes
- Proposals can be canceled at any time if the voting weight of the proposer falls below the configurable threshold
- The single call can be to `Timelock#queue(calls)`, which may execute multiple calls
- The contract has no owner, and cannot be updated nor re-configured.

#### Timelock

`Timelock` allows a list of calls to be executed after a configurable delay by its owner

- Anyone can execute the calls after a period of time, once queued by the owner
- Designed to be the principal agent in representation of the DAO, i.e. hold all assets
- The contract has an owner, and may be upgraded or configured via a call to self.

#### Factory

`Factory` creates the set of governance contracts (`Staker`, `Timelock`, `Governor`) in a single call.

## Testing

Make sure you have [Scarb with asdf](https://docs.swmansion.com/scarb/download#install-via-asdf) installed.

To run unit tests:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.
