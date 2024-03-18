# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Contracts for token-based governance on Starknet.

## Components

Contracts in this repository are designed so that they may be used together _or_ independently.

### Distribution

#### Airdrop

`Airdrop` is a highly-optimized distribution contract for distributing a fungible ERC20-like token to many (`O(1e6)`) accounts. To use it, you must compute a binary merkle tree using the pedersen hash function of an `id`-sorted list of `Claim` structs. The root of this tree and the token address are passed as constructor arguments and cannot change.

- Compute a merkle root by producing a list of `Claim` structs, hashing them, sorting by sequentially-assigned ID, and arranging them into a merkle binary tree
  - Claim IDs must be sorted, start from `0` and be contiguous to make optimal use of the contract's `claim_128` entrypoint
- Deploy the airdrop with the `root` from this merkle tree and the token address
- Transfer the total amount of tokens to the `Airdrop` contract
- Unclaimed tokens can be refunded to the specified-at-construction `refund_to` address after the `refundable_timestamp`, _iff_ `refundable_timestamp` is not zero

### Governance

#### Staker

`Staker` enables users to delegate the balance of a token towards an account, and tracks the historical delegation at each block. In addition, it allows the computation of the time-weighted average delegated tokens of any account over any historical period.

- Users call `Token#approve(staker, stake_amount)`, then `Staker#stake(delegate)` to stake and delegate their tokens to other addresses
- Users call `Staker#withdraw(delegate, recipient, amount)` to remove part or all of their delegation
- The average delegation weight is computable over *any* historical period
- The contract has no owner, and cannot be updated nor configured.

#### Governor

`Governor` enables stakers to vote on whether to make a _single_ call.

- A user's voting weight for a period is determined by their average delegation according to the staker over the `voting_weight_smoothing_duration`
- A delegate may create a proposal to make a `call` if their voting weight exceeds the threshold
- After the `voting_start_delay`, users may choose to vote yea or nay on the proposal for the `voting_period`. A user's vote weight is computed based on the start time of the proposal.
- If a proposal receives at least quorum in voting weight, the simple majority of total votes is yea, and the voting period is over, the proposal may be executed exactly once
  - If the call fails, the transaction will revert, and the call may be re-executed
- Proposals can be canceled at any time by anyone if the voting weight of the proposer falls below the configurable threshold
- The only thing stored regarding a proposal is the call that it makes, along with the metadata
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
