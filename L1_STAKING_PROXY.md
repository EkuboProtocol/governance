# L1-Controlled Staking Proxy

This document describes the L1-controlled staking system that allows Ethereum smart contracts (like Gnosis Safe multisigs) to control EKUBO token staking on Starknet.

## Overview

The system consists of two main components:

1. **L2 Contract (`L1StakingProxy`)**: A Cairo contract on Starknet that holds and manages staked EKUBO tokens
2. **L1 Contract (`StarknetStakingProxy`)**: A Solidity contract on Ethereum that sends messages to control the L2 contract

## Architecture

```
┌─────────────────┐    L1→L2 Messages    ┌──────────────────┐
│   Ethereum L1   │ ──────────────────→  │   Starknet L2    │
│                 │                      │                  │
│ StarknetStaking │                      │  L1StakingProxy  │
│     Proxy       │                      │                  │
│                 │                      │        │         │
│ (Gnosis Safe    │                      │        ▼         │
│  or EOA)        │                      │   Staker Contract│
└─────────────────┘                      └──────────────────┘
```

## Features

### L2 Contract (L1StakingProxy)

- **L1 Ownership**: Only the designated L1 address can control the contract
- **Upgradeable**: Contract implementation can be upgraded via L1 messages
- **Staking Operations**: Stake and withdraw EKUBO tokens through the existing Staker contract
- **Emergency Functions**: Emergency token transfer capabilities
- **Arbitrary Calls**: Execute any calls for maximum flexibility

### L1 Contract (StarknetStakingProxy)

- **Owner-Controlled**: Only the owner (can be a multisig) can send messages
- **Specialized Methods**: Easy-to-use methods for common staking operations
- **Message Encoding**: Automatically encodes messages for L2 consumption
- **Event Logging**: Comprehensive event logging for transparency

## Usage

### Deployment

#### 1. Deploy L2 Contract

```cairo
// Deploy with constructor parameters:
// - l1_owner: Ethereum address that will control this contract
// - staker: Address of the existing Staker contract
// - token: Address of the EKUBO token contract

let l1_owner = 0x1234567890123456789012345678901234567890; // Your L1 address
let staker = /* existing staker contract address */;
let token = /* EKUBO token contract address */;
```

#### 2. Deploy L1 Contract

```solidity
// Set environment variables:
// L2_STAKING_PROXY_ADDRESS=<deployed L2 contract address>
// OWNER_ADDRESS=<your multisig or EOA address>
// PRIVATE_KEY=<deployment private key>

forge script script/DeployStaking.s.sol --rpc-url $RPC_URL --broadcast
```

### Operations

#### Staking Tokens

```solidity
// From your L1 contract (or multisig):
stakingProxy.stake{value: messageFee}(
    delegate,  // Address to delegate voting power to
    amount     // Amount of tokens to stake (u128)
);
```

#### Withdrawing Tokens

```solidity
stakingProxy.withdraw{value: messageFee}(
    delegate,   // Address currently delegated to
    recipient,  // Address to receive withdrawn tokens
    amount      // Amount to withdraw (u128)
);
```

#### Emergency Transfer

```solidity
stakingProxy.emergencyTransfer{value: messageFee}(
    token,      // Token contract address
    recipient,  // Address to receive tokens
    amount      // Amount to transfer (u256)
);
```

#### Contract Upgrade

```solidity
stakingProxy.upgrade{value: messageFee}(
    newClassHash  // New implementation class hash
);
```

### Message Fees

All L1→L2 operations require ETH to pay for Starknet message fees. The contract accepts ETH via the `{value: messageFee}` parameter.

## Security Considerations

### Access Control

- **L1 Owner**: Only the designated L1 address can send messages to the L2 contract
- **L2 Internal**: L2 contract methods are only callable internally via L1 messages
- **Ownership Transfer**: L1 contract ownership can be transferred (useful for multisig upgrades)

### Upgradability

- The L2 contract is upgradeable via L1 messages
- Upgrades require the same L1 owner authorization as other operations
- Consider using a multisig for the L1 owner to prevent single points of failure

### Emergency Functions

- Emergency transfer allows recovery of any tokens held by the L2 contract
- This is a safety mechanism in case of issues with the staking contract
- Should be used sparingly and with proper governance

## Integration Examples

### Gnosis Safe Integration

```solidity
// 1. Deploy contracts with Gnosis Safe as owner
// 2. Create transaction in Safe UI:
//    - To: StarknetStakingProxy address
//    - Value: Message fee amount
//    - Data: stakingProxy.stake(delegate, amount)
// 3. Get required signatures and execute
```

### Direct EOA Usage

```solidity
// Direct interaction from an EOA:
IStarknetStakingProxy proxy = IStarknetStakingProxy(proxyAddress);
proxy.stake{value: 0.01 ether}(delegateAddress, 1000e18);
```

## Events

The contracts emit comprehensive events for monitoring:

### L1 Events
- `StakeMessageSent(delegate, amount, nonce)`
- `WithdrawMessageSent(delegate, recipient, amount, nonce)`
- `EmergencyTransferMessageSent(token, recipient, amount, nonce)`

### L2 Events
- `Staked(delegate, amount)`
- `Withdrawn(delegate, recipient, amount)`
- `EmergencyTransferExecuted(token, recipient, amount)`
- `L1MessageHandled(from_address, operation)`

## Error Handling

### Common Errors

- `UNAUTHORIZED_L1_CALLER`: Message not from authorized L1 address
- `INVALID_PAYLOAD`: Malformed message payload
- `TRANSFER_FROM_FAILED`: Token transfer failed (check allowances)
- `INSUFFICIENT_AMOUNT_STAKED`: Trying to withdraw more than staked

### Debugging

1. Check L1 transaction succeeded and message was sent
2. Verify L2 contract received and processed the message
3. Check token balances and allowances
4. Review event logs for detailed error information

## Gas and Fee Considerations

- L1 operations require ETH for Starknet message fees
- Message fees vary based on L1 gas prices and L2 congestion
- Consider batching operations when possible
- Monitor fee costs and adjust accordingly

## Future Enhancements

Potential improvements to consider:

1. **Batch Operations**: Support for multiple operations in a single message
2. **Delegation Management**: More sophisticated delegation strategies
3. **Yield Farming**: Integration with additional DeFi protocols
4. **Governance Integration**: Direct voting capabilities from L1
5. **Fee Optimization**: More efficient message encoding to reduce costs
