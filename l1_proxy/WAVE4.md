# Gnosis and Polygon owner proxies (`AMBOwnerProxy`, `FxPortalOwnerProxy`)

Owner proxies for chains whose canonical Ethereum bridge reports the Ethereum sender instead of aliasing it.
Both are controlled by the Ethereum `StarknetOwnerProxy` `0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc`, which only
the Starknet Governor can drive. Nothing in this directory deploys or sends anything by itself.

| Chain | Contract | Constructor arguments | Ethereum entry point |
|---|---|---|---|
| Gnosis (100) | `AMBOwnerProxy` | `l1Owner = 0x1e0e…e9cc`, `amb = HomeAMB 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59`, `sourceChainId = 1` | ForeignAMB `0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e` `requireToPassMessage(proxy, executeBatch(calls), 500000)` |
| Polygon PoS (137) | `FxPortalOwnerProxy` | `l1Owner = 0x1e0e…e9cc`, `fxChild = 0x8397259c983751DAf40400790063935a11afa28a` | FxRoot `0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2` `sendMessageToChild(proxy, abi.encode(calls, deadline))` |

## Rules the contracts enforce

- **Immutable Ethereum owner (CSO EKU-1047 F2 / R1).** `l1Owner` is immutable and is the only identity accepted
  over the bridge. There is no direct-call path. `transferOwnership`, `renounceOwnership`,
  `requestOwnershipHandover`, `completeOwnershipHandover` and `cancelOwnershipHandover` always revert, and a batch
  cannot call the proxy itself. To move control, the DAO sends `Positions/Orders.transferOwnership(newProxy)` through
  the current proxy.
- **One atomic batch per message (N1).** A message carries `Call[] {target, value, data}`; every call succeeds or
  the whole message reverts. A proposal sends one message per chain, so delivery order never matters.
- **AMB authentication (R2).** `msg.sender == HomeAMB`, `messageSender() == l1Owner`,
  `messageSourceChainId() == bytes32(1)`. HomeAMB marks a message processed even when the call fails
  (`messageCallStatus = false`) and never runs it again, so a failed message is final.
- **Fx authentication and ordering (R2, F1).** `msg.sender == FxChild`, `rootMessageSender == l1Owner`,
  `stateId > lastStateId` (then stored), and `block.timestamp <= deadline`. A reverted delivery is stored by
  StateReceiver and anyone can replay it (PIP-36); it can only execute while no newer message has executed and the
  deadline has not passed. A failed delivery does not advance `lastStateId`. A newer message, even an empty batch,
  supersedes every stored failure.
- **Finality.** Neither bridge exposes a finality flag on the destination. AMB validators wait 175 Ethereum
  confirmations before affirming (`requiredBlockConfirmations`); Polygon state syncs are committed by Heimdall
  from finalized Ethereum events. The trust set is the bridge's own (CSO EKU-1047 N2).

## Rules for the proposal author

- **Deadline (Fx).** At most 14 days after the earliest time the L1 message can be relayed
  (`created + 352800` for the Starknet Governor). If the message has not executed by then, it expires and needs a
  new proposal. The contract does not cap the deadline: a cap checked at delivery would turn a too-far deadline into
  a stored failure that later becomes replayable, which is worse than executing it on first delivery.
- **AMB gas.** `500000` (HomeAMB `maxGasPerTx` is 2,000,000). The two-handover batch uses well under 100k.
- **One message per chain per proposal.** Put every call for a chain into the same batch.
- Use `script/wave4-l1-calldata.sh` to build the Ethereum-side calls from the deployed proxy addresses, the
  proposal creation time and the deadline. It **fails** unless
  `PROPOSAL_CREATED + 352800 < FX_DEADLINE <= PROPOSAL_CREATED + 352800 + 14 days` (CSO EKU-1064 D4a; both sides
  are tested by `script/wave4-l1-calldata.test.sh`), reads `currentNonce()` live (Gnosis gets `currentNonce`,
  Polygon `currentNonce + 1`; `EXPECT_NONCE` pins it), decodes both delivered messages and requires exactly
  `requestOwnershipHandover()` on Positions and Orders v3.2, and prints per message the L1 call, the
  `getPayload(target, 0, nonce, data)` felts the Governor sends, the L2→L1 message hash, and the inner message with
  its keccak256, in the manifest's "Exact L1 calldata per message" format, with gas estimated from the L1 proxy.
  With `GNOSIS_RPC_URL` / `POLYGON_RPC_URL` it also checks that the company key still owns both targets and that a
  deployed proxy's runtime code hash equals the reference.

## Deployment (R4)

1. `forge script script/DeployWave4OwnerProxy.s.sol:DeployWave4OwnerProxy --rpc-url <gnosis|polygon> --broadcast …`.
   Before deploying it checks that `l1Owner` has no code on the chain and that the bridge contracts are the
   canonical ones (HomeAMB source 100 / destination 1; `FxChild.fxRoot() == FxRoot`). After deploying it checks
   every immutable.
2. `PROXY=<address> forge script script/DeployWave4OwnerProxy.s.sol:VerifyWave4OwnerProxy --rpc-url <chain>`
   re-runs the checks and requires the deployed runtime code to equal a reference build with the canonical
   arguments (solc 0.8.28, via-ir, 9,999,999 runs).
3. Verify the source on Gnosisscan / Polygonscan.

## Handover and monitoring (R5, R6)

- Proof that a route works is the `OwnershipHandoverRequested(pendingOwner = proxy)` event from Positions/Orders in
  the delivery transaction (HomeAMB `executeAffirmation` or StateReceiver `commitState` / `replayFailedStateSync`).
  The company key calls `completeOwnershipHandover(proxy)` only after observing it, inside the 48 h window.
- Monitor `OwnershipTransferred` and `OwnershipHandoverRequested` on Positions/Orders on both chains, the proxy's
  `Executed(messageId, callCount)` event (AMB message id, or the Fx `stateId`), and bridge deprecation notices.

## Tests

- `test/Wave4OwnerProxies.t.sol`: unit tests with mock bridges, including the CSO EKU-1047 F1 and F2 proofs of
  concept (now rejected) and a fuzzed `stateId` ordering property.
- `test/Wave4OwnerProxiesFork.t.sol`: end to end on Ethereum, Gnosis and Polygon forks. The Ethereum leg calls the
  live ForeignAMB / FxRoot from the L1 proxy; the emitted payload is delivered through the live HomeAMB (affirmed
  by the live validators, impersonated) or StateReceiver → FxChild (Bor system call, impersonated). Covers the
  handover of the live Positions and Orders, a failed AMB message being final and atomic, a foreign Ethereum sender,
  the PIP-36 replay before and after the deadline, a stale replay after a newer message, and migration to a new
  proxy. Run with `ETH_RPC_URL`, `GNOSIS_RPC_URL` and `POLYGON_RPC_URL` set (skipped otherwise; optional
  `*_FORK_BLOCK`).
