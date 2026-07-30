# Cross-Chain Routes

## Common Starknet-to-Ethereum envelope

The Governor cannot synchronously call Ethereum. It self-calls `send_message_to_l1`, Starknet
proves the message to Ethereum, and a permissionless relayer calls:

```solidity
StarknetOwnerProxy.execute(l1Target, l1Value, nonce, l1Data)
```

That call:

1. checks the exact sequential nonce;
2. consumes the message from Starknet Core using the configured Governor as `l2Owner`; and
3. calls `l1Target` with `l1Value` and `l1Data`.

If consumption or the target call fails, the transaction reverts, including the nonce increment.
The proposal's message contents remain immutable, so a permanently inadequate fee cap cannot be
repaired by changing calldata.

Build the payload with the deployed view:

```sh
cast call "$PROPOSAL_L1_PROXY" \
  'getPayload(address,uint256,uint64,bytes)(uint256[])' \
  "$PROPOSAL_L1_TARGET" "$PROPOSAL_L1_VALUE" "$PROPOSAL_L1_NONCE" \
  "$PROPOSAL_L1_DATA" --json --rpc-url "$PROPOSAL_ETH_RPC"
```

For a direct Ethereum action, set `PROPOSAL_L1_TARGET` and `PROPOSAL_L1_DATA` to the final contract
and call. For another L2, target that chain's canonical Ethereum messenger.

## Arbitrum and Orbit L1-to-L2 route

Use the chain's canonical Delayed Inbox:

```solidity
createRetryableTicket(
    address to,
    uint256 l2CallValue,
    uint256 maxSubmissionCost,
    address excessFeeRefundAddress,
    address callValueRefundAddress,
    uint256 gasLimit,
    uint256 maxFeePerGas,
    bytes data
)
```

Construct the inner owner-proxy call:

```sh
PROPOSAL_L2_DATA=$(cast calldata \
  'execute(address,uint256,bytes)' \
  "$PROPOSAL_FINAL_TARGET" "$PROPOSAL_FINAL_VALUE" "$PROPOSAL_FINAL_DATA")
```

Then construct Inbox calldata:

```sh
PROPOSAL_L1_DATA=$(cast calldata \
  'createRetryableTicket(address,uint256,uint256,address,address,uint256,uint256,bytes)' \
  "$PROPOSAL_L2_OWNER_PROXY" 0 "$PROPOSAL_MAX_SUBMISSION_COST" \
  "$PROPOSAL_EXCESS_REFUND" "$PROPOSAL_CALLVALUE_REFUND" \
  "$PROPOSAL_L2_GAS_LIMIT" "$PROPOSAL_L2_MAX_FEE_PER_GAS" "$PROPOSAL_L2_DATA")
```

Set:

```text
l1Target = canonical Delayed Inbox
l1Value = l2CallValue + maxSubmissionCost + gasLimit * maxFeePerGas
l1Data = encoded createRetryableTicket call
```

Use `l2CallValue = 0` because `L1L2OwnerProxy.execute` is nonpayable. If
`PROPOSAL_FINAL_VALUE` is nonzero, pre-fund the destination owner proxy through its payable
`receive` function before executing the governance action.

An L1 contract sender is aliased on Arbitrum or Orbit. Confirm:

```text
expected_alias = address(uint160(l1_owner) + 0x1111000000000000000000000000000000001111)
```

Check the deployed proxy's `l2OwnerAlias()` and simulate the actual owner-proxy call with
`cast call --from <expected_alias>`. Also verify that an unrelated sender reverts.

At proposal finalization:

- calculate the current minimum submission fee through the Inbox;
- estimate the actual inner L2 call gas;
- add margin for the later execution window;
- verify the L1 proxy balance covers the encoded value;
- choose valid destination-chain refund addresses; and
- document retryable monitoring and manual redemption.

## OP Stack L1-to-L2 route

Use the target chain's canonical Ethereum `L1CrossDomainMessenger` to send calldata to the deployed
`OPStackOwnerProxy`. The inner calldata is:

```solidity
OPStackOwnerProxy.execute(finalTarget, finalValue, finalData)
```

Encode the chain's supported messenger call, commonly:

```solidity
sendMessage(address target, bytes message, uint32 minGasLimit)
```

Do not assume the messenger address, ABI version, value behavior, or gas rules. Verify them from the
live chain and official chain deployment records.

On the destination chain, `OPStackOwnerProxy` requires:

- `msg.sender == 0x4200000000000000000000000000000000000007`; and
- `xDomainMessageSender() == Ethereum StarknetOwnerProxy`.

Simulate both the correct messenger context and a wrong L1 sender. Pre-fund the owner proxy before a
nonzero forwarded call unless the verified messenger and entrypoint combination safely supplies
value.

## Relaying and ordering

Document the complete operational sequence:

1. Execute the passed proposal on Starknet.
2. Wait until the L2-to-L1 message is consumable on Ethereum.
3. Call `StarknetOwnerProxy.execute` with the exact target, value, nonce, and bytes.
4. Monitor L1-to-L2 delivery.
5. Redeem or retry the destination message when required.
6. Verify final state on every affected chain.

When a batch emits multiple L1 messages, assign sequential nonces and execute them in order. When
separate proposals could overlap, coordinate them explicitly; reading the same current nonce for
two proposals creates a race.
