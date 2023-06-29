# Ekubo Governance

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Simple-as contracts for token governance on Starknet.

## Principles

Contracts follow the Compound governance philosophy.
Contracts are focused on immutability.
All contracts are intended to be upgraded by simply migrating to new ones, including even the token contract if necessary.

The structure is as follows:

- Timelock is an owned contract that allows a list of calls to be queued by an owner
    - Anyone can execute the calls after a period of time, once queued by the owner
    - Timelock is meant to own all assets, and never be upgraded
- Governance contract manages voting on a set of calls that can be queued into a timelock
    - Meant to own the timelock contract
    - Timelock may be transferred to a new governance contract in future, e.g. to migrate to a volition-based contract
- Token represents the voting right
    - Manages both delegates and a delegate accumulator which can be used to compute arithmetic mean number of votes over a period of time 
- Airdrop can be used to distribute Token
    - Compute a merkle root by computing a list of amounts and recipients, pedersen hashing them, and arranging them into a merkle binary tree

