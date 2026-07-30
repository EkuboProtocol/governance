---
name: build-cross-chain-proposals
description: Construct, audit, simulate, and serialize Ekubo Starknet Governor proposals, including actions routed through Ethereum to Arbitrum, Orbit chains such as Robinhood Chain, Optimism, or Base. Use when preparing proposal call lists, owner-proxy or bridge calldata, checking cross-chain ownership and fees, writing proposal documents, or producing the comma-delimited calls accepted by the interface Create Proposal page.
---

# Build Cross-Chain Proposals

Produce a governance proposal whose primary artifact is a verified, single-line call list that can
be pasted into **Import** on the Starknet Create Proposal page in the sibling `interface` repository.
Treat prose, decoded calls, and simulations as evidence for that artifact.

## Load the relevant references

- Always read [references/interface-import-format.md](references/interface-import-format.md).
- For any action leaving Starknet, read
  [references/cross-chain-routes.md](references/cross-chain-routes.md).
- When resolving deployed addresses, read
  [references/mainnet-deployments.md](references/mainnet-deployments.md), then verify every
  address and dynamic value onchain.

## Follow the workflow

### 1. Establish the exact action

1. Resolve the governance repository root with `git rev-parse --show-toplevel`.
2. Identify the source and ABI for every target and intermediary.
3. Record the source chain, destination chain ID, final target, function, arguments, native value,
   and expected state transition.
4. Distinguish the governance release from protocol-contract releases. Never infer a Governor
   version from the `starknet-contracts` version.
5. Stop for clarification if the final target, value, or authority-changing effect is ambiguous.

### 2. Pin and verify live state

Use `sncast call`, Starknet JSON-RPC, and `cast call` against explicit RPC URLs. Keep credentials in
environment variables and never place keys in proposal files, commands committed to git, or output.
Record the block number used for each chain.

Verify at minimum:

- the Governor address, live class hash, required entrypoints, and relevant configuration;
- the Ethereum `StarknetOwnerProxy` bytecode, `l2Owner`, `l2MessageBridge`, `currentNonce`, and
  balance;
- the destination owner proxy bytecode, `owner`, authenticated alias or messenger path, and
  balance;
- the canonical bridge contracts, destination chain ID, pause state, allowlist state, and message
  path;
- the final target's ownership, roles, current state, and ability to accept the intended call;
- all native-value and fee requirements.

Treat nonces, balances, fee quotes, gas estimates, implementations, pause flags, and ownership as
dynamic. Re-read them immediately before finalizing the import line.

### 3. Encode from the innermost call outward

Use ABI-aware tools instead of hand-writing selectors or EVM ABI words:

- Use `cast calldata` for EVM calls.
- Use `sncast utils selector` for Cairo entrypoint selectors.
- Use the deployed `StarknetOwnerProxy.getPayload` view for the exact L1 message payload.

For a cross-chain action, construct in this order:

1. Encode the final target call.
2. Wrap it in the destination `ArbitrumOwnerProxy.execute` or `OPStackOwnerProxy.execute`.
3. Wrap that call in the canonical L1-to-L2 bridge message.
4. Set the Ethereum `StarknetOwnerProxy.execute` target, value, nonce, and data.
5. Call the deployed proxy's `getPayload(target,value,nonce,data)`.
6. Create a Starknet call to the Governor itself:
   - `to`: Governor
   - `selector`: `send_message_to_l1`
   - `calldata`: Ethereum `StarknetOwnerProxy`, payload length, then payload words
7. Combine this call with any direct Starknet calls in the required atomic order.

Never manually reproduce the 31-byte chunk packing when the deployed `getPayload` function is
available.

### 4. Serialize for the interface

Represent the final Starknet calls as JSON:

```json
[
  {
    "contract_address": "0x...",
    "selector": "0x...",
    "calldata": ["0x...", "0x..."]
  }
]
```

Run:

```sh
python3 .agents/skills/build-cross-chain-proposals/scripts/serialize_calls.py encode calls.json
```

The script emits the exact comma-delimited line for the Create Proposal page. Decode it again as an
independent structural check:

```sh
python3 .agents/skills/build-cross-chain-proposals/scripts/serialize_calls.py decode import.txt
```

Do not include the proposal description or `propose_and_describe` wrapper in the import line. The
interface adds those separately.

### 5. Simulate every layer

Perform read-only checks before calling the proposal ready:

1. Simulate the innermost target call from the destination owner proxy.
2. Simulate the destination proxy call from the expected Arbitrum alias or OP messenger context.
3. For Arbitrum or Orbit, dry-run `createRetryableTicket` from the Ethereum owner proxy with the
   intended value and fee caps.
4. Confirm the deployed `getPayload` output round-trips to the exact L1 target, value, nonce, and
   bytes.
5. Simulate the Starknet proposal calls from the Governor at a pinned accepted block and inspect
   calls, events, messages, and state diff.
6. Paste or parse the final line through the sibling interface's import grammar. Confirm its
   simulation panel shows the intended effects.

A transport-only simulation does not prove that an unspecified final target action will succeed.
Simulate the actual final target and calldata.

### 6. Write the proposal record

Create or update `proposals/<descriptive-slug>.md` with:

- summary and motivation;
- exact deployment addresses and pinned verification blocks;
- preconditions and expected post-state;
- execution order and why it is safe;
- fee, balance, nonce, relaying, and retry instructions;
- simulation and test evidence;
- the single-line interface-importable call list;
- a decoded call table.

Keep the import line in one fenced `text` block with no commentary inside it.

## Enforce cross-chain safety

- Serialize `StarknetOwnerProxy` messages by nonce. Two pending messages using the same nonce race;
  only the first successful execution can use it.
- Choose retryable fee caps for the future L1 execution time, not merely current fees. Ensure the
  Ethereum proxy remains funded for the encoded `value`.
- Set Arbitrum or Orbit retryable `l2CallValue` to zero when calling the nonpayable owner-proxy
  `execute`. Pre-fund the destination proxy before forwarding nonzero native value.
- Use refund addresses that are valid and controllable on the destination chain.
- Document the permissionless L1 relayer step and monitor retryable auto-redemption or expiry.
- Preserve call ordering when an ownership transfer would remove authority needed by later calls.
- Re-run all reads and simulations if any nonce, class hash, implementation, ownership, bridge
  state, fee assumption, or target calldata changes.

## Completion criteria

Return a proposal as ready only when:

- every address and dynamic assumption has pinned onchain evidence;
- each nested layer decodes to the intended next call;
- authorization succeeds for the canonical cross-chain sender and fails for an unrelated sender;
- the actual target action and full Starknet call batch simulate successfully;
- the serializer decodes the final import line without loss;
- the decoded table exactly matches the import line; and
- the primary handoff includes the one-line interface-importable data.
