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

- Users call `Token#approve(staker, stake_amount)`, then `Staker#stake_amount(delegate, stake_amount)` to stake and delegate their tokens to other addresses
- Users call `Staker#withdraw_amount(delegate, recipient, amount)` to remove part or all of their delegation
- The average delegation weight is computable over _any_ historical period
- The contract has no owner, and cannot be updated nor configured

#### Governor

`Governor` enables stakers to vote on whether to make a batch of calls.

- A user's **voting weight** for a period is determined by their average total delegation over the period `voting_weight_smoothing_duration`
- A delegate may create a proposal to make a batch of `calls` if their voting weight exceeds the proposal creation threshold
- After the `voting_start_delay`, users may choose to vote `yea` or `nay` on the created proposal for the duration of the `voting_period`
  - A voter's voting weight is computed based on their average delegation over the period `voting_weight_smoothing_duration` from before the start time of the proposal
- If a proposal receives at least `quorum` in voting weight, and the simple majority of total votes is `yea`, and the voting period is over, the proposal may be executed exactly once
  - Must happen after the voting has ended and the execution delay has passed
  - If any of the calls fails, the transaction will revert, and anyone may attempt to execute the proposal again, up until the end of the execution window
- Proposals can be canceled at any time by _anyone_ iff the voting weight of the proposer falls below the proposal creation threshold, up until it is executed
- The proposer may also cancel the proposal at any time before the end of the voting period
- Proposers may only have one active proposal at any time
- The contract can be upgraded via calls to self

#### StarknetOwnerProxy.sol: L1 Proxy

`StarknetOwnerProxy` enables the L2 governor contract to perform actions on L1 via proposals that call `self#send_message_to_l1`.

- The `EthAddress` should be the address of a `StarknetOwnerProxy` referencing the Governor L2 address
- The payload can be computed by calling the `getPayload` view function on the deployed `StarknetOwnerProxy`
- Once the message is accepted on L1, anyone can call `StarknetOwnerProxy#execute` with the proposal's specified `target`, `value` and `data`.

## Testing

Make sure you have [Scarb with asdf](https://docs.swmansion.com/scarb/download#install-via-asdf) installed. You can look at the _.tool-versions_ file to know which version of Scarb is currently used.

To run unit tests:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.
