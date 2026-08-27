# Return TWAMM balances that no order can claim

## Summary

Three TWAMM orders deposited tokens that the TWAMM's own accounting can no longer attribute to
anyone. The tokens are still held by Core under the TWAMM's saved balance, but no function on the
deployed TWAMM can pay them back.

This proposal installs a temporary implementation, `TWAMMRefund`, pays the affected owners, and
restores the current TWAMM implementation — all in one atomic execution, so the TWAMM is never
left in the temporary state between transactions.

Total returned: **50,000.000000 USDC** and **1.250015 STRK**, to three addresses.

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

Verified at Starknet mainnet block **13,930,653** (2026-08-27 05:55:55 UTC).

| Order NFT | Sell → Buy | Ended (UTC) | Stranded | Cause |
| --- | --- | --- | --- | --- |
| `2288050` (`0x22e9b2`) | USDC → STRK | 2026-08-24 19:48:16 | 50,000.000000 USDC | pool liquidity 0 for 102 days |
| `559381` (`0x88915`) | STRK → USDC.e | 2024-08-17 01:42:24 | 1.250000 STRK | pool liquidity 64 (negligible) |
| `1314066` (`0x140d12`) | STRK → USDC.e | 2025-06-20 16:44:48 | 0.000010 STRK | sale rate below rounding |
| `1315586` (`0x141302`) | STRK → USDC.e | 2025-06-23 17:33:52 | 0.000005 STRK | sale rate below rounding |

Every one of these reads `purchased_amount = 0` and `remaining_sell_amount = 0` from
`TWAMM.get_order_info`, and reports `total_proceeds_withdrawn = 0` with
`last_collect_proceeds = null` on the production API — they were never collected and never
refunded, so the deposit is untouched.

`2288050` is the largest by three orders of magnitude and is the order that prompted this work: it
sold 50,000 USDC for STRK over 4.5 hours into a USDC/STRK pool whose liquidity had been zero since
2026-05-14. The 50,000.000000 USDC entered Core in the placement transaction
`0x03eec3a74271a3321d7692d275a7b594f6c109ae6c2797bf6b32f513af7faaeb`, and the TWAMM's USDC saved
balance rose by exactly that amount and has never fallen back below it.

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
`2288050` this reproduces exactly `50000000000`, matching the USDC transferred in the placement
transaction to the unit.

## Preconditions

- `TWAMMRefund` class hash `0x03d781303a16960d64c9ceedc906c6aabf8879a24f061c2d9eeb2fc7001a329f`
  **must be declared on mainnet before this proposal executes.** It is not deployed as a contract;
  only the class is needed.
- The TWAMM's owner must remain the Governor. Verified: `TWAMM.get_owner()` returns
  `0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd`.
- The TWAMM's live class hash must remain `0x07f60fe1d7e48bb51695f675de0475325d2d131a81fc87144023ae437fcfac32`,
  so that call 3 restores exactly what is running today. Verified with `starknet_getClassHashAt`.

## Expected post-state

- USDC saved balance for the TWAMM falls by `50000000000`; STRK falls by `1250015000000000000`.
- The three recipients receive those amounts.
- The TWAMM's class hash is unchanged from before execution.
- No order state is written. `TWAMMRefund` reads and writes no TWAMM order storage.

## Execution order

1. Replace the TWAMM class with `TWAMMRefund`.
2. Pay the three refunds.
3. Replace the TWAMM class with the current implementation.

The order matters: the refund entrypoint only exists while step 1's class is installed. Execution is
atomic, so a failure in any call reverts all three and the TWAMM keeps its current class. Because
governance execution is a single transaction, the TWAMM is never observable in the temporary state.

`TWAMMRefund` reports the TWAMM's primary interface id rather than its own, so both class
replacements satisfy the id check in `Upgradeable#replace_class_hash`. Its storage declares `core`,
`upgradeable`, and `owned` at the same names — and therefore the same addresses — as the TWAMM's, so
the owner and Core address already written by the TWAMM are read back correctly.

## Safety

- `refund` is owner-gated, so only the Governor can call it, and only while the temporary class is
  installed.
- `core.load` asserts `amount <= saved_balance` (`core.cairo:617`), so a refund can never draw on
  tokens the TWAMM was not already holding. The requested amounts are well inside the balances:
  50,000.000000 of 52,254.348612 USDC, and 1.250015 of 22,767.414912 STRK.
- `TWAMMRefund` implements nothing else. It cannot place, modify, or settle orders, and it holds no
  upgrade authority beyond the inherited owner-gated `replace_class_hash`.

## Recipients

Each recipient is the **current** owner of the corresponding order NFT, not the original placer.
If an NFT is transferred between the creation of this proposal and its execution, the refund would
pay the earlier owner. That race is accepted; the addresses should be re-read before the vote
closes.

## Verification

- `starknet-contracts` suite: **613 passed, 0 failed**, 1 intentionally ignored. `scarb fmt --check`
  clean.
- `src/tests/twamm_refund_test.cairo` reproduces the stranded state — an order into a
  zero-liquidity pool run past its end time — then upgrades, refunds, and upgrades back, asserting
  the owner is made whole, the saved balance is drained, and the TWAMM still accepts orders
  afterwards. Owner-only, the insufficient-balance guard, and multi-recipient payloads are covered.
- The import line below was produced by
  `.agents/skills/build-cross-chain-proposals/scripts/serialize_calls.py encode` and decoded again
  with the same script's `decode` without loss.
- Class hashes, TWAMM ownership, saved balances, per-order state, and pool liquidity were all read
  from mainnet at block 13,930,653.

### Not yet done

- The call batch has **not** been simulated from the Governor. Simulation requires the
  `TWAMMRefund` class to be declared on mainnet first, because call 1 replaces the class with it.
  Declare the class, then simulate, before voting.
- The stranded-order enumeration used an indexer snapshot whose head was 2026-08-26 00:03 UTC.
  Every listed candidate was re-verified against the live production API, but orders that ended
  after that snapshot are not covered. Re-run the enumeration against a current indexer before
  submitting, and extend the list if it grows.
- A `purchased_amount` of 0 is only final once the pool has executed virtual orders past the
  order's `end_time`. This was proven for `2288050`, whose pool executed 25 hours after its end.
  It was **not** checked for `559381`, `1314066`, or `1315586` — and `1314066`'s pool still holds
  liquidity. If one of those pools has an unexecuted window, a later `execute_virtual_orders` could
  turn `purchased_amount` positive, making a full-deposit refund a small overpayment out of the
  shared pot. Exposure is bounded by 1.250015 STRK, so nothing material is at risk, but the
  re-run above should confirm `last_virtual_order_time > end_time` for each of those three pools —
  or simply drop them and refund only `2288050`.

## Interface-importable call list

Paste the single comma-delimited line below into **Import calls** on the Starknet proposal creation
page:

```text
0x3,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x30417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x3d781303a16960d64c9ceedc906c6aabf8879a24f061c2d9eeb2fc7001a329f,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x3d967966e6b0ea40f78dff297fed3b472763137dac6cf564d7263e918f425ef,0xa,0x3,0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,0x562324206226171d83c6fea52c5bc0f7d84bda124049e62f1515a0578331b66,0x1158e460913d0000,0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,0x2ee3ba455b15b2f6624b993dafc4c61df4e9c96390343bea236756830a8e03b,0xda475abf000,0x33068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb,0x77e016835a96edccd2405179d4c81a1f28c040b77603bd367e1e651c447eb1e,0xba43b7400,0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x30417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x7f60fe1d7e48bb51695f675de0475325d2d131a81fc87144023ae437fcfac32
```

### Decoded calls

| # | Target | Function | Calldata |
| ---: | --- | --- | --- |
| 1 | TWAMM `0x043e4f09…8fdc` | `replace_class_hash(class_hash)` | `TWAMMRefund` `0x03d78130…329f` |
| 2 | TWAMM `0x043e4f09…8fdc` | `refund(Array<Refund>)` | 3 refunds, below |
| 3 | TWAMM `0x043e4f09…8fdc` | `replace_class_hash(class_hash)` | `TWAMM` `0x07f60fe1…ac32` |

Call 2 calldata, as `[len, (token, recipient, amount)…]`:

| # | Token | Recipient | Amount |
| ---: | --- | --- | --- |
| 1 | STRK `0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d` | `0x0562324206226171d83c6fea52c5bc0f7d84bda124049e62f1515a0578331b66` | `0x1158e460913d0000` = 1.250000 STRK |
| 2 | STRK `0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d` | `0x02ee3ba455b15b2f6624b993dafc4c61df4e9c96390343bea236756830a8e03b` | `0xda475abf000` = 0.000015 STRK |
| 3 | USDC `0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb` | `0x077e016835a96edccd2405179d4c81a1f28c040b77603bd367e1e651c447eb1e` | `0xba43b7400` = 50,000.000000 USDC |

## Related

- Contract: [EkuboProtocol/starknet-contracts#207](https://github.com/EkuboProtocol/starknet-contracts/pull/207)
- The interface now blocks new orders into zero-liquidity pools and above 1% one-block price impact
  (`EkuboProtocol/interface` `61a26d8f`), and no longer hides zero-fill orders from both the open
  and closed tabs (`b5dc3352`). Neither is a contract-level guard; that remains open.
