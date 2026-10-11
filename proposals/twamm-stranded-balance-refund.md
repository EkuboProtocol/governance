# Return TWAMM balances that no order can claim

## Status: executed — USDC only

> **Executed on Starknet mainnet on 2026-09-19.** Governor proposal
> `0x727b53063708fddc8c623b8e5272cec162a402b005b45f64d6a67816551f27e` (created 2026-09-14 19:34:44
> UTC) was executed in transaction
> [`0x26d8794f0597786ec56454d8eff4dd66a2b15b077b7e121f837ddf7614f679c`](https://voyager.online/tx/0x26d8794f0597786ec56454d8eff4dd66a2b15b077b7e121f837ddf7614f679c),
> block **15,134,669**, 2026-09-19 21:36:41 UTC, `SUCCEEDED` / `ACCEPTED_ON_L1`.
>
> What executed differs from the earlier draft of this document:
>
> - **One refund, not three.** Only order `2288050` was refunded: **50,000.000000 USDC** to
>   `0x077e016835a96edccd2405179d4c81a1f28c040b77603bd367e1e651c447eb1e`.
> - **The STRK entries were dropped.** The 1.250015 STRK stranded on orders `559381`, `1314066` and
>   `1315586` was **not refunded** and is still in the TWAMM's saved balance. See
>   [Not refunded](#not-refunded-stranded-strk).
> - **The batch had six calls, not three.** Calls 4–6 were unrelated to the TWAMM: they send three
>   messages to the L1 `StarknetOwnerProxy` to fund the Limit Orders recovery. See
>   [Executed call list](#executed-call-list).
>
> The draft's three-refund import line has been removed. **Do not re-submit it**: it asks for
> 50,000 USDC, and the TWAMM's USDC saved balance is now below 1,000 USDC (755.010537 at block
> 15,639,041), so it would revert with `INSUFFICIENT_SAVED_BALANCE`. The draft remains readable at
> commit `d8686d1`.

## Summary

Some TWAMM orders deposited tokens that the TWAMM's own accounting can no longer attribute to
anyone. The tokens are held by Core under the TWAMM's saved balance, but no function on the deployed
TWAMM can pay them back.

The executed proposal installed a temporary implementation, `TWAMMRefund`, paid the owner of the
largest affected order, and restored the current TWAMM implementation — all in one atomic execution,
so the TWAMM was never left in the temporary state between transactions.

Total returned: **50,000.000000 USDC**, to one address.

## Motivation

An order that sells into a pool it cannot trade against fills nothing, but is still consumed by the
clock.

`internal_execute_virtual_orders` takes its one-sided branch, calls `core.swap` with the price limit
at the extreme, and receives a zero delta — there is nothing to trade against. `reward_rate` never
advances, so `purchased_amount` stays 0. Meanwhile `remaining_sell_amount` is pure time-decay
arithmetic and reaches 0 on schedule regardless.

Once `end_time` passes there is no exit:

- collecting proceeds pays `purchased_amount`, which is 0;
- refunding requires `UpdateSaleRate`, which asserts `current_time < end_time`
  (`twamm.cairo:366`, `ORDER_ENDED`).

The deposit remains in Core under `SavedBalanceKey { owner: TWAMM, token, salt: 0 }`. That key has
no per-order component, so the tokens sit in a pot shared across every order and every pool, with
no claimant. Left alone, an unattributed surplus in a shared pot silently absorbs future rounding
shortfalls, so the balance should be returned rather than left in place.

Two distinct conditions produced this:

1. **No liquidity.** The pool had none for the whole order, so every virtual-order execution
   swapped zero.
2. **Sale rate below rounding.** The sale rate was so small that each execution interval's amount
   rounded down to zero, so nothing was ever sold.

Both leave the full deposit stranded, and neither is recoverable by the order owner.

## Affected orders

Identified at Starknet mainnet block **13,930,653** (2026-08-27 05:55:55 UTC).

| Order NFT | Sell → Buy | Ended (UTC) | Stranded | Cause | Refunded |
| --- | --- | --- | --- | --- | --- |
| `2288050` (`0x22e9b2`) | USDC → STRK | 2026-08-24 19:48:16 | 50,000.000000 USDC | pool liquidity 0 for 102 days | **yes**, tx `0x26d8794f…679c` |
| `559381` (`0x88915`) | STRK → USDC.e | 2024-08-17 01:42:24 | 1.250000 STRK | pool liquidity 64 (negligible) | no |
| `1314066` (`0x140d12`) | STRK → USDC.e | 2025-06-20 16:44:48 | 0.000010 STRK | sale rate below rounding | no |
| `1315586` (`0x141302`) | STRK → USDC.e | 2025-06-23 17:33:52 | 0.000005 STRK | sale rate below rounding | no |

Every one of these stranded order keys reads `purchased_amount = 0` and `remaining_sell_amount = 0`
from `TWAMM.get_order_info`, and reports `total_proceeds_withdrawn = 0` with
`last_collect_proceeds = null` on the production API.

`2288050` is the largest by three orders of magnitude and is the order that prompted this work: it
sold 50,000 USDC for STRK over 4.5 hours into a USDC/STRK pool whose liquidity had been zero since
2026-05-14. The 50,000.000000 USDC entered Core in the placement transaction
`0x03eec3a74271a3321d7692d275a7b594f6c109ae6c2797bf6b32f513af7faaeb`, and the TWAMM's USDC saved
balance rose by exactly that amount and did not fall back below it until the refund.

### How the list was produced

All 10,981 TWAMM order keys on Starknet mainnet were enumerated from the indexer and read back
on-chain through `TWAMM.get_order_info`. An order is stranded only when all of the following hold:

- its `end_time` has passed;
- `purchased_amount` is 0, so there are no proceeds to collect;
- `remaining_sell_amount` is 0, so there is nothing left to sell;
- no proceeds withdrawal was ever recorded; and
- its deposits exceed its refunds.

That yields 25 candidates, of which 20 belong to the RevenueBuybacks position `2287818`. Those 20
are **not** stranded: the production API shows every one collected at `1787796165`, after the local
indexer snapshot was taken. They are excluded. Five order keys across four NFTs remain, listed
above.

Orders that filled but have not been collected are deliberately excluded — 532 of them. Their
owners can still collect normally, and paying them here would double-pay.

## Deposit amounts

Each refund is the amount actually deposited, not the time-decayed "amount sold" the API reports.
Deposits round **up** (`round_up: !sale_rate_delta.sign`), while the sold figure rounds down, so the
two differ by up to one unit per order. Refunding the sold figure would leave dust behind; refunding
more than the deposit would revert.

Amounts are recomputed with the contract's own formula,
`ceil(sale_rate * duration / 2^32)` where `duration = end_time - max(start_time, block_time)`. For
`2288050` this reproduces exactly `50000000000` — `ceil(13238094242386882 × 16222 / 2^32)` —
matching the USDC transferred in the placement transaction to the unit.

## Executed call list

Six calls, executed atomically by the Governor in transaction `0x26d8794f…679c`. Calls 1–3 are the
TWAMM refund. Calls 4–6 are Governor self-calls to `send_message_to_l1`, which the proposal
description presents as funding the Limit Orders recovery from the L1 treasury; they run after the
TWAMM class was restored and do not touch the TWAMM.

| # | Target | Function | Arguments |
| ---: | --- | --- | --- |
| 1 | TWAMM `0x043e4f09…8fdc` | `replace_class_hash(class_hash)` | `TWAMMRefund` `0x03d78130…329f` |
| 2 | TWAMM `0x043e4f09…8fdc` | `refund(Array<Refund>)` | 1 refund, below |
| 3 | TWAMM `0x043e4f09…8fdc` | `replace_class_hash(class_hash)` | `TWAMM` `0x07f60fe1…ac32` |
| 4 | Governor `0x053499f7…9acd` | `send_message_to_l1(to, payload)` | L1 proxy, nonce 25: USDC `transfer` |
| 5 | Governor `0x053499f7…9acd` | `send_message_to_l1(to, payload)` | L1 proxy, nonce 26: EKUBO `transfer` |
| 6 | Governor `0x053499f7…9acd` | `send_message_to_l1(to, payload)` | L1 proxy, nonce 27: Positions NFT `transferFrom` |

Call 2 calldata, as `[len, (token, recipient, amount)…]`:

| # | Token | Recipient | Amount |
| ---: | --- | --- | --- |
| 1 | USDC `0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb` | `0x077e016835a96edccd2405179d4c81a1f28c040b77603bd367e1e651c447eb1e` | `0xba43b7400` = 50,000.000000 USDC |

Calls 4–6 all message the L1 `StarknetOwnerProxy` `0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc`. Each
payload is `[target, value, nonce, data_len, data…]`, with the L1 calldata packed into 31-byte
chunks. Decoded:

| # | Nonce | L1 target | L1 call | Amount / id |
| ---: | ---: | --- | --- | --- |
| 4 | 25 | USDC `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | `transfer(0x00000c771f6176268d5a9846e0956c3ef58597a1, 27000809728)` | 27,000.809728 USDC |
| 5 | 26 | EKUBO `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` | `transfer(0x00000c771f6176268d5a9846e0956c3ef58597a1, 15381290500925225319523)` | 15,381.290500925225319523 EKUBO |
| 6 | 27 | Ekubo Positions `0x02d9876a21af7545f8632c3af76ec90b5ad4b66d` | `transferFrom(0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc, 0x00000c771f6176268d5a9846e0956c3ef58597a1, id)` | one NFT, id `0x21d48bf274c9f0b8c73175d788e472fe81ec90d6ae2ac656385f42c0d43b8fc2` |

The three messages were consumed on L1 in transaction
[`0x7d44c639e37326bf4c28f9b78f2f306ac4112b6a8815970ea5899b2afa126b98`](https://etherscan.io/tx/0x7d44c639e37326bf4c28f9b78f2f306ac4112b6a8815970ea5899b2afa126b98),
block 26,021,748, 2026-09-20 22:35:11 UTC.

Executed calldata, in the Import-calls format, for verification only. It equals the calldata of
transaction `0x26d8794f…679c` felt for felt, and round-trips through
`.agents/skills/build-cross-chain-proposals/scripts/serialize_calls.py`. **Do not import it into a
new proposal** — call 2 would revert, and calls 4–6 would re-send the L1 transfers.

```text
0x6,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x30417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x3d781303a16960d64c9ceedc906c6aabf8879a24f061c2d9eeb2fc7001a329f,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x3d967966e6b0ea40f78dff297fed3b472763137dac6cf564d7263e918f425ef,0x4,0x1,0x33068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb,0x77e016835a96edccd2405179d4c81a1f28c040b77603bd367e1e651c447eb1e,0xba43b7400,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x30417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x7f60fe1d7e48bb51695f675de0475325d2d131a81fc87144023ae437fcfac32,0x53499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd,0x28148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007,0x9,0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc,0x7,0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48,0x0,0x19,0x44,0xa9059cbb00000000000000000000000000000c771f6176268d5a9846e0956c,0x3ef58597a10000000000000000000000000000000000000000000000000000,0x6495fa90000000000000000000000000000000000000000000000000000,0x53499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd,0x28148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007,0x9,0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc,0x7,0x4c46e830bb56ce22735d5d8fc9cb90309317d0f,0x0,0x1a,0x44,0xa9059cbb00000000000000000000000000000c771f6176268d5a9846e0956c,0x3ef58597a1000000000000000000000000000000000000000000000341d249,0x2905922e3c6300000000000000000000000000000000000000000000000000,0x53499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd,0x28148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007,0xa,0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc,0x8,0x2d9876a21af7545f8632c3af76ec90b5ad4b66d,0x0,0x1b,0x64,0x23b872dd0000000000000000000000001e0ef4162e42c9bf820c307218c4e4,0x1ccca6e9cc00000000000000000000000000000c771f6176268d5a9846e095,0x6c3ef58597a121d48bf274c9f0b8c73175d788e472fe81ec90d6ae2ac65638,0x5f42c0d43b8fc2000000000000000000000000000000000000000000000000
```

## Observed post-state

Read from mainnet at the blocks before and after execution.

| Check | Block 15,134,668 | Block 15,134,669 |
| --- | --- | --- |
| TWAMM class hash | `0x07f60fe1…ac32` | `0x07f60fe1…ac32` (restored) |
| TWAMM owner | Governor `0x053499f7…9acd` | Governor `0x053499f7…9acd` |
| TWAMM saved USDC | 51,290.251827 | 1,290.251827 (−50,000.000000) |
| TWAMM saved STRK | 28,698.951501… | unchanged |
| Recipient USDC | 148,283.299377 | 198,283.299377 (+50,000.000000) |

- Events emitted by the TWAMM in the transaction, in order: `ClassHashReplaced` →
  `0x03d78130…329f`, `Refunded(USDC, 0x077e0168…eb1e, 50000000000)`, `ClassHashReplaced` →
  `0x07f60fe1…ac32`. No `OwnershipTransferred`. The Governor emitted `Executed` for the proposal
  with 6 calls, and the receipt carries 3 L2→L1 messages.
- The recipient was `owner_of(2288050)` at both blocks.
- 50,000 of 51,290.251827 USDC saved at execution, so the refund stayed inside the TWAMM's own
  balance.
- The TWAMM kept running on the restored class: virtual orders executed from block 15,134,687
  onward, and new orders were placed.
- Execution fee: 7.137 STRK.

## Not refunded: stranded STRK

The executed proposal dropped the three STRK entries. **1.250015 STRK** remains stranded in the
TWAMM's STRK saved balance, which held 8,117.597954 STRK at block 15,643,772.

Read at block 15,643,772 (2026-09-29 20:10 UTC), owner = Positions, salt = NFT id:

| Order NFT | Owner | Fee (hex) | `sale_rate` | `remaining_sell_amount` | `purchased_amount` | Pool `last_virtual_order_time` | Stranded? |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| `559381` | `0x05623242…1b66` | `0x68db8bac…` | 5120000000000000000000 | 0 | 0 | 2026-02-08 | **yes**, 1.250000 STRK |
| `559381` | | `0x20c49ba5…` | 15360000000000000000000 | 0 | 1,423,972 (1.423972 USDC.e) | 2026-03-26 | no — collectible |
| `1314066` | `0x02ee3ba4…e03b` | `0x68db8bac…` | 1555912680815094339 | 0 | 0 | 2026-02-08 | **yes** |
| `1314066` | | `0xc49ba5e3…` | 1685572070883018867 | 0 | 0 | 2026-09-29 | **yes** |
| `1315586` | `0x02ee3ba4…e03b` | `0x68db8bac…` | 1721567779381112714 | 0 | 0 | 2026-02-08 | **yes** |
| `1315586` | | `0xc49ba5e3…` | 170435210158730158730 | 0 | 51 (0.000051 USDC.e) | 2026-09-29 | no — collectible |

- Every pool has executed virtual orders past the order's `end_time`, so the zero
  `purchased_amount` readings are final. That closes the finality question the draft left open.
- The sibling order keys on `559381` and `1315586` did fill. Their proceeds are still collectible
  through the normal path and must never be included in a refund. The draft's per-NFT amounts
  covered only the zero-purchase keys and were correct on that basis.
- Neither owner has ever collected those claimable proceeds: `last_collect_proceeds` is `null` on
  all six keys, including 1.423972 USDC.e claimable on `559381` since August 2024.

**No second proposal is recommended for this amount.**

- **Value.** 1.250015 STRK in total. The 0.000015 STRK on `1314066` and `1315586` is dust.
- **Cost exceeds value.** A refund-only batch simulated at a fee of about 0.271 STRK, about a fifth
  of the refund, before counting a vote and pre-vote review of a live TWAMM class replacement.
- **Risk is not proportionate.** Each `replace_class_hash` on the live TWAMM is a live-contract
  upgrade. `TWAMMRefund` is only safe while the TWAMM keeps the storage layout of class
  `0x07f60fe1…ac32`, so any reuse needs a fresh security review.
- **Leaving it is harmless.** It stays in the TWAMM's salt-0 STRK saved balance as a small
  unattributed surplus, like the dust the pot already absorbs.

If a later proposal installs `TWAMMRefund` for a material amount, these three entries can be
appended at negligible marginal cost. Before that, re-read `owner_of` and saved balances, and
re-check that the TWAMM class is still `0x07f60fe1…ac32`.

## Execution design

The order matters: the refund entrypoint only exists while call 1's class is installed. Execution is
atomic, so a failure in any call reverts all of them and the TWAMM keeps its current class. Because
governance execution is a single transaction, the TWAMM was never observable in the temporary state.

`TWAMMRefund` reports the TWAMM's primary interface id rather than its own, so both class
replacements satisfy the id check in `Upgradeable#replace_class_hash`. Its storage declares `core`,
`upgradeable`, and `owned` at the same names — and therefore the same addresses — as the TWAMM's, so
the owner and Core address already written by the TWAMM are read back correctly.

### Safety

- `refund` is owner-gated, so only the Governor can call it, and only while the temporary class is
  installed.
- `core.load` asserts `amount <= saved_balance` (`core.cairo:617`), so a refund can never draw on
  tokens the TWAMM was not already holding.
- `TWAMMRefund` implements nothing else. It cannot place, modify, or settle orders, and it holds no
  upgrade authority beyond the inherited owner-gated `replace_class_hash`.

## Classes

- `TWAMMRefund` class hash `0x03d781303a16960d64c9ceedc906c6aabf8879a24f061c2d9eeb2fc7001a329f`,
  declared on mainnet in transaction
  `0x05a9d43aff7b4110322e5c45afd698bcb6a23f7b36f06588ee8cef819bb1dc1d`. It was never deployed as a
  contract; only the class was needed.
- Both `TWAMMRefund` and the restored `TWAMM` class `0x07f60fe1…ac32` reproduce exactly from
  `starknet-contracts` #207 head `b2f23e9`, and from that head merged onto current `main`, with
  `scarb 2.20.0 --release build`.

## Verification history

- `starknet-contracts` suite at #207: **613 passed, 0 failed**, 1 intentionally ignored.
  `scarb fmt --check` clean. `src/tests/twamm_refund_test.cairo` reproduces the stranded state — an
  order into a zero-liquidity pool run past its end time — then upgrades, refunds, and upgrades back,
  asserting the owner is made whole, the saved balance is drained, and the TWAMM still accepts orders
  afterwards. Owner-only, the insufficient-balance guard, and multi-recipient payloads are covered.
- Before submission, the **draft** three-refund list (not the executed six-call batch) was simulated
  from the Governor and succeeded, with the TWAMM class net unchanged. `Governor.__execute__` only
  accepts a query transaction version (`governor.cairo:486`), so a batch is reachable in simulation
  and not by direct invoke. No pre-execution simulation of the executed batch is on record.
- After execution, the executed call list was decoded from transaction `0x26d8794f…679c` and matched
  against the indexed proposal. State reads before and after execution are recorded in
  [Observed post-state](#observed-post-state).

## Related

- Contract: [EkuboProtocol/starknet-contracts#207](https://github.com/EkuboProtocol/starknet-contracts/pull/207)
- The interface now blocks new orders into zero-liquidity pools and above 1% one-block price impact
  (`EkuboProtocol/interface` `61a26d8f`), and no longer hides zero-fill orders from both the open
  and closed tabs (`b5dc3352`). Neither is a contract-level guard; that remains open.
