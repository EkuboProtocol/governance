# Mainnet Deployment Reference

Treat these as discovery anchors from committed deployment records, not substitutes for live reads.
Verify bytecode, ownership, bridge configuration, and chain ID before every proposal.

## Governance roots

| Contract | Chain | Address | Repository evidence |
| --- | ---: | --- | --- |
| Governor | Starknet | `0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd` | `proposals/starknet-v5-upgrade-and-buybacks.md` |
| StarknetOwnerProxy | Ethereum, 1 | `0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc` | `l1_proxy/broadcast/Deploy.s.sol/1/run-latest.json` |
| Starknet Core messaging | Ethereum, 1 | `0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4` | immutable constructor argument in the same deployment |

The `StarknetOwnerProxy.l2Owner` constructor value decodes to the Governor address above.

## Destination owner proxies

| Contract | Chain | Chain ID | Address | Deployment record |
| --- | --- | ---: | --- | --- |
| ArbitrumOwnerProxy | Arbitrum One | 42161 | `0x2ed25dec49800edb237de812ab9a4c37b74d3282` | `l1_proxy/broadcast/DeployArbitrumOwnerProxy.s.sol/42161/run-latest.json` |
| ArbitrumOwnerProxy | Robinhood Chain | 4663 | `0xcd87828f4f279d3c5fd7af531370298964b5eaab` | `l1_proxy/broadcast/DeployArbitrumOwnerProxy.s.sol/4663/run-latest.json` |
| OPStackOwnerProxy | Optimism | 10 | `0xcad6e08e0532d523c10825821d10e3f7c845b0c0` | `l1_proxy/broadcast/DeployOPStackOwnerProxy.s.sol/10/run-latest.json` |
| OPStackOwnerProxy | Base | 8453 | `0xd46197c8c5cba977c4c287f04ddc77f2dc105067` | `l1_proxy/broadcast/DeployOPStackOwnerProxy.s.sol/8453/run-latest.json` |

Every deployment record sets the Ethereum `StarknetOwnerProxy` as owner. Confirm this live.

## Robinhood canonical messaging

| Contract | Layer | Address |
| --- | --- | --- |
| Delayed Inbox | Ethereum | `0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D` |
| Bridge | Ethereum | `0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3` |
| Sequencer Inbox | Ethereum | `0xBd0D173EEb87D57A09521c24388a12789F33ba96` |
| Outbox | Ethereum | `0xf0ce991ea4A0d2400A4AB49b20ae333f6Dce3DE9` |
| Rollup | Ethereum | `0x23A19d23e89166adedbDcB432518AB01e4272D94` |
| ArbSys | Robinhood | `0x0000000000000000000000000000000000000064` |

Authoritative references:

- [Robinhood cross-chain messaging](https://docs.robinhood.com/chain/cross-chain-messaging/)
- [Robinhood protocol contracts](https://docs.robinhood.com/chain/protocol-contracts/)

The Arbitrum alias offset used by the repository is:

```text
0x1111000000000000000000000000000000001111
```

For the Ethereum owner proxy, the expected Robinhood alias is:

```text
0x2f1Ff4162E42c9BF820C307218c4E41cCCA6FadD
```

## Historical audit snapshot

On 2026-07-30, read-only RPC checks established:

- the Ethereum proxy executable bytecode matched the repository contract after immutable
  substitution;
- its `l2Owner` matched the Governor and its messaging bridge matched Starknet Core;
- the Robinhood proxy was an exact runtime-bytecode match, owned by the Ethereum proxy, and
  accepted the expected alias while rejecting an unrelated sender;
- the Robinhood Delayed Inbox was unpaused, not allowlisted, registered with its bridge, and tied
  to Rollup chain ID `4663`;
- an `eth_call` dry run of `createRetryableTicket` from the Ethereum proxy succeeded;
- the live Governor still used its prior class, while the governance v2.8.0 class was declared,
  rebuilt to the expected class hash, and retained `send_message_to_l1`.

Do not reuse the nonce, balances, fee quote, gas quote, or class hash from that snapshot. Query
current state.
