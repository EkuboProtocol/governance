# Upgrade Ekubo Starknet contracts to v5.0.2 and Governor to v2.8.0

## Summary

This proposal upgrades every upgradeable Ekubo mainnet Starknet contract to the
classes released from:

- [`governance` v2.8.0](https://github.com/EkuboProtocol/governance/releases/tag/v2.8.0)
- [`starknet-contracts` v5.0.2](https://github.com/EkuboProtocol/starknet-contracts/releases/tag/v5.0.2)

It also completes the migration from Core-collected protocol fees to
Positions-collected protocol fees:

- Core stops accruing protocol fees and its obsolete fee-rate slot is cleared.
- Positions applies a fixed 20% protocol fee when position fees are collected.
- A newly deployed RevenueBuybacks instance sources those fees from Positions.
- Core and Positions ownership move to that new RevenueBuybacks instance.

The Governor remains the owner of RevenueBuybacks and can reclaim either Core
or Positions through a future proposal.

## Motivation

The protocol release:

- fixes low-price and exact-input swap precision;
- adds fuzzed Starknet math invariants;
- removes the TWAMM cancellation fee when decreasing a sale rate;
- moves the Oracle initialization snapshot from the pre-initialize hook to the
  post-initialize hook;
- emits explicit extension call-point changes;
- externalizes protocol-fee accounting from Core to Positions; and
- upgrades Governor behavior so active-proposal checks use the proposal's
  configuration version and tied votes fail because passage requires
  `yea > nay`.

Both repositories build with Scarb 2.20.0 and use Starknet Foundry 0.62.1.

## Mainnet deployment

The new, non-upgradeable RevenueBuybacks contract has already been deployed:

| Item | Value |
| --- | --- |
| Address | `0x019a118a52687c9cfa7b6b195b29587946adf04564949753f381215b446621e0` |
| Class hash | `0x0541b3c83dd84751816030726768dd924fd2c4a6efcf95efa9a5eb103b18a4fa` |
| Class declaration transaction | `0x0217a1ceb3d65b5f5338e96397b1be88e630832f3e86ae87af1fb5165bce3493` |
| Deployment transaction | `0x02be0b2f0c983c3b5a692669f36155808bfc208be225937f269084ceec5e7fb2` |
| Owner | Governor, `0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd` |
| Core | `0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b` |
| Positions | `0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067` |
| Positions token ID | `2287817` |
| Buy token | EKUBO, `0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87` |
| Minimum / maximum start delay | `0` / `10800` seconds |
| Minimum / maximum order duration | `259200` / `604800` seconds |
| TWAMM pool fee | `0xc49ba5e353f7d00000000000000000` (0.3% in 0.128 fixed point) |

The deployment transaction succeeded on L2, and its constructor state,
ownership, referenced contracts, configuration, minted token ID, and NFT
ownership were read back from mainnet.

## Class upgrades

| Contract | Mainnet address | Current class hash | New class hash | Declaration transaction |
| --- | --- | --- | --- | --- |
| Governor | `0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd` | `0x05f4217c83694d6cfa21c70e587c45a3e97e0243564741f889d2c40c3ced6574` | `0x044e2e3d2ae1b0415450b2b5d417698ce495f7ef500826ddb48a61f9dfe67401` | `0x01b3b06a9f3305b0e6f122cce6c10318ae6b0371a5c2f9907d29d514ce47c5a5` |
| Core | `0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b` | `0x0577604a2611c851e9cfc4da2ba7f7fc1d44a9327cc734d68b2b271340a6551c` | `0x0423df19e032f2d9bf9bb5bc1ea96db2b06d4c752c8c130cba7d577eed1de20a` | `0x03be464dc773a2425879fc9623cfab5635bd19fcdd1000df5ff12746c38a7afb` |
| Positions | `0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067` | `0x0c12f7c0a0bf73e3675345a8d28d26c83db3b13605f2aa33cba8344a0f582b5` | `0x006a3ba97c623a9e6abeffa5db5726f68ba5cec842de80922b8825effe68d21d` | `0x0461cafb375c147d005066eaa30772fdfea5b2287551d16ce6c007d0ef66308f` |
| Positions NFT | `0x07b696af58c967c1b14c9dde0ace001720635a660a8e90c565ea459345318b30` | `0x05ad546a6c28eb16584335a4f717918199ffde7e722131ef518df23ec55a34d4` | `0x0509c0b913cd309048269018617a20eef51d9cd42397416be9b212169637f4e4` | `0x0290ef7558a9a1fe07709052ad93afa5560b134b43c356dd6431f9c2f54d312d` |
| TWAMM | `0x043e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc` | `0x0131e8a1b84559246f3743584740446c28f7fd885d5859d63d2883d1002d80ba` | `0x07f60fe1d7e48bb51695f675de0475325d2d131a81fc87144023ae437fcfac32` | `0x036c777db5689dcfdb51d4ef499977bd67a09bab5dc89a4d685602e7d0e981a2` |
| Limit Orders | `0x050ed6ab03aef492cd062e25facf40ceef63294c53d12b514226f8fb4753266e` | `0x0666ebe000503c67313863b91fb9ed3c1b52e90b77c5045210449449739b3126` | `0x03eb7123a1786c08b4fdeb49b6ae839f8b43f5e06d4d4066cad309e182cf40a4` | `0x06d095e6f4e7313367647c3abed6f72fef4df72e7df437b5cec7c834b43763be` |
| Oracle | `0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f` | `0x05811dfbc1f38392aa3e9580178ee2b5bf48fe9ee421ba709625e447d51bfe76` | `0x04453a062e94ac6294c359270755596c00c21b7bf014ce55ace0f3c3de421100` | `0x05eecca19d78729a0b5ba369b0b63c722e2c9daef7fa860e25663520465d7bc3` |

This is the complete upgradeable mainnet scope. Staker, Airdrop and claim
helpers, Router, TokenRegistry, PriceFetcher, StreamedPayment, and both
RevenueBuybacks deployments do not expose a class-replacement path. The latest
classes for those contracts were still declared for reproducible deployments,
but they are not targets of this proposal.

## Execution order

The calls are deliberately ordered as follows:

1. Ask the old RevenueBuybacks contract to return Core ownership to Governor.
2. Upgrade Core.
3. Clear Core's obsolete fee-rate slot. This does not clear collected token balances.
4. Upgrade Positions.
5. Upgrade the Positions-owned NFT through Positions.
6. Upgrade TWAMM.
7. Upgrade Limit Orders.
8. Upgrade Oracle.
9. Re-register Oracle's new hook configuration with Core.
10. Transfer Core ownership to the new RevenueBuybacks contract.
11. Transfer Positions ownership to the new RevenueBuybacks contract.
12. Upgrade Governor last, avoiding a class replacement in the middle of its
    execution loop.

Ownership transfers are last among the protocol calls so Governor retains the
authority required by every preceding upgrade. The entire proposal execution
is atomic.

## Storage compatibility

Storage was compared against the last live releases, governance v2.4.0 and
starknet-contracts v4.0.2.

| Contract | Compatibility result |
| --- | --- |
| Governor | Compatible. The ordered storage fields and their types remain `staker`, `config_versions`, `latest_config_version`, `nonce`, `proposals`, `latest_proposal_by_proposer`, and `vote`. Stored proposal/config/execution-state layouts are unchanged. |
| Core | Compatible. Existing fields and component substorages retain their names and types. `core_protocol_fee` remains at the same key as a legacy no-op slot, and `protocol_fees_collected` remains available for already-collected balances. |
| Positions | Compatible. No existing storage field is added, removed, renamed, or retyped. New protocol fees use Core saved-balance accounting keyed by Positions, token, and the `PROTOCOL_FEES` salt. |
| Positions NFT | Compatible. Storage and owned/upgradeable component layouts are unchanged. |
| TWAMM | Compatible. Storage layout is unchanged. |
| Limit Orders | Compatible. Storage layout is unchanged. |
| Oracle | Compatible. Storage layout is unchanged; only the registered initialize-pool hook changes. |
| RevenueBuybacks | Not an in-place upgrade. A fresh immutable instance was deployed and initialized. |

Existing Core protocol-fee token balances are intentionally preserved by the
upgrade. This payload does not start legacy Core buybacks because those calls
require absolute start and end timestamps constrained to a 3-to-7-day duration,
which would make a reusable governance payload execution-time dependent.
Governor can later call `reclaim_core` on the new RevenueBuybacks contract,
withdraw or process those balances in a time-bounded proposal, and return Core
ownership. New protocol fees accrue to Positions and are available to the new
RevenueBuybacks instance.

## Verification

- Governance test suite: 158 passed, 0 failed.
- Starknet contracts test suite: 609 passed, 0 failed, 1 intentionally ignored.
- `scarb fmt --check` passes in both repositories.
- Every release-profile production class was accepted on Starknet mainnet.
- RevenueBuybacks deployment and constructor state were verified onchain.
- The exact call list below was round-tripped through the interface import
  format and simulated as a version-3 invoke from Governor while the latest
  accepted mainnet block was 12,264,825.
- The successful simulation state diff replaces all seven classes, clears the
  Core fee-rate slot, registers Oracle call points as `0xd0`, and sets both Core
  and Positions owners to the new RevenueBuybacks address.

## Interface-importable call list

Paste the single comma-delimited line below into **Import calls** on the
Starknet proposal creation page:

```text
0xc,0x00f2e9a400ba65b13255ef2792612b45d5a20a7a7cf211ffb3f485445022ef72,0x01f921e0ed43449f30cf7d5711c19faf7009dbd0021eac07fdc2bf503971e576,0x0,0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,0x030417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x0423df19e032f2d9bf9bb5bc1ea96db2b06d4c752c8c130cba7d577eed1de20a,0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,0x006f8edd634063a272519cbcbf5cc1191c118202fe88a69cbc07f65eccf1a56c,0x0,0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067,0x030417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x006a3ba97c623a9e6abeffa5db5726f68ba5cec842de80922b8825effe68d21d,0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067,0x031f94d8f73906bb4afe3a32993567018c788c8399254929053bbd170e576b3f,0x1,0x0509c0b913cd309048269018617a20eef51d9cd42397416be9b212169637f4e4,0x043e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc,0x030417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x07f60fe1d7e48bb51695f675de0475325d2d131a81fc87144023ae437fcfac32,0x050ed6ab03aef492cd062e25facf40ceef63294c53d12b514226f8fb4753266e,0x030417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x03eb7123a1786c08b4fdeb49b6ae839f8b43f5e06d4d4066cad309e182cf40a4,0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f,0x030417ba66711d4fb2e476476f41af5c08b9ddfb34c07d269d33fceed59a842b,0x1,0x04453a062e94ac6294c359270755596c00c21b7bf014ce55ace0f3c3de421100,0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f,0x0397ef51c187819cfc617c4a5b9986ade3cd2cced7efd91b53f4f4989a18a71c,0x0,0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,0x02a3bb1eaa05b77c4b0eeee0116a3177c6d62319dd7149ae148185d9e09de74a,0x1,0x019a118a52687c9cfa7b6b195b29587946adf04564949753f381215b446621e0,0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067,0x02a3bb1eaa05b77c4b0eeee0116a3177c6d62319dd7149ae148185d9e09de74a,0x1,0x019a118a52687c9cfa7b6b195b29587946adf04564949753f381215b446621e0,0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd,0x00f2f7c15cbe06c8d94597cd91fd7f3369eae842359235712def5584f8d270cd,0x1,0x044e2e3d2ae1b0415450b2b5d417698ce495f7ef500826ddb48a61f9dfe67401
```

### Decoded calls

| # | Target | Function | Calldata |
| ---: | --- | --- | --- |
| 1 | Old RevenueBuybacks | `reclaim_core()` | — |
| 2 | Core | `replace_class_hash(class_hash)` | New Core class hash |
| 3 | Core | `clear_core_protocol_fee()` | — |
| 4 | Positions | `replace_class_hash(class_hash)` | New Positions class hash |
| 5 | Positions | `upgrade_nft(class_hash)` | New Positions NFT class hash |
| 6 | TWAMM | `replace_class_hash(class_hash)` | New TWAMM class hash |
| 7 | Limit Orders | `replace_class_hash(class_hash)` | New Limit Orders class hash |
| 8 | Oracle | `replace_class_hash(class_hash)` | New Oracle class hash |
| 9 | Oracle | `set_call_points()` | — |
| 10 | Core | `transfer_ownership(new_owner)` | New RevenueBuybacks address |
| 11 | Positions | `transfer_ownership(new_owner)` | New RevenueBuybacks address |
| 12 | Governor | `upgrade(class_hash)` | New Governor class hash |
