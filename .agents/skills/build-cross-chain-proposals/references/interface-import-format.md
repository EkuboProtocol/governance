# Interface Import Format

## Source of truth

When the sibling repository exists, inspect:

- `../interface/src/pages/starknet/StarknetCreateProposal.tsx`
- `../interface/src/util/starknet/types.ts`
- `../interface/src/util/starknet/l1Payload.ts`

The Create Proposal page imports calls only. It separately supplies the proposal description and
wraps the imported calls in `propose_and_describe`.

## Grammar

Use one comma-delimited sequence:

```text
call_count,to,selector,calldata_length,calldata_0,...,to,selector,calldata_length,...
```

For each call:

1. `to` is one Starknet contract-address felt.
2. `selector` is one felt.
3. `calldata_length` is the number of calldata felts, not the number of bytes.
4. Exactly `calldata_length` felt values follow.

The first value is the number of calls. Parsing must end exactly after the final call. The interface
accepts decimal or `0x`-prefixed values and normalizes them, but emit minimal `0x`-prefixed values
for consistency.

Example:

```text
0x2,0x111,0xaaa,0x2,0x1,0x2,0x222,0xbbb,0x0
```

This represents:

```json
[
  {
    "contract_address": "0x111",
    "selector": "0xaaa",
    "calldata": ["0x1", "0x2"]
  },
  {
    "contract_address": "0x222",
    "selector": "0xbbb",
    "calldata": []
  }
]
```

## Cross-chain Governor call

For `Governor.send_message_to_l1(to_address, payload)`, the imported Starknet call is:

- `to`: the Starknet Governor address;
- `selector`: the Cairo selector for `send_message_to_l1`;
- `calldata[0]`: the Ethereum `StarknetOwnerProxy` address;
- `calldata[1]`: the number of payload felts;
- `calldata[2..]`: the exact output of
  `StarknetOwnerProxy.getPayload(l1_target,l1_value,current_nonce,l1_data)`.

The current mainnet selector is:

```text
0x28148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007
```

Recompute it with `sncast utils selector send_message_to_l1` and confirm it exists in the live
Governor class before use.

## Validation

Use `scripts/serialize_calls.py` to encode and decode the line. Also paste it into the Create
Proposal page and confirm:

- imported call count;
- each target, selector, and calldata;
- the decoded L1 message;
- simulation success and expected state diff.
