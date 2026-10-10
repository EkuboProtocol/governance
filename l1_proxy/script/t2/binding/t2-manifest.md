# EKU-1280 T2 real-delivery testnet manifest, bounded budget and binding rules (A′-CCIP owner route)

**Status: PREPARED, NOT AUTHORIZED.** No key was generated, fetched or used. No faucet was requested. No testnet or mainnet transaction was signed or sent. Nothing was merged or deployed. Every test ran on a local EVM, local anvil forks, local snforge or read-only public RPC.

This revision (EKU-1280) replaces the EKU-1272 manifest (`d5f7c2b2…c209c241f`, PR #87 head `9287094`). It is **test-only**: it adds the CSO EKU-1274 E-1 post-return `DEPLOY_ACCOUNT` tamper regressions (§11) so that each field of the reserved deploy intent (class hash, salt, constructor calldata, receipt `contract_address`) has a killing test. `t2_guard.py`, budget, limits, caps, gates and the R2-D pre-secret derivation are byte-unchanged.

The EKU-1272 revision replaced the EKU-1268 manifest (`2e87e401…26c7`, PR #87 head `65e094e`). It closes CFO EKU-1269 R2-D (the undeployed Starknet account address is **derived** from the pinned class, salt and public key and matched to every bound address field and the funding recipient before any keystore, password or signer, §5/§7), adds killing tests for all nine CSO EKU-1270 D-1 mutant survivors, binds the EVM keystore sha256 per signing role (D-2), and contains the D-3 residuals (§7, §10). Budget, limits and caps are unchanged.

The EKU-1268 revision replaced the EKU-1261 manifest (`dcd5a142…d44e`, PR #87 head `5bab186`). It closes CFO EKU-1263 R1 (durable reservation **before** signing) and R2 (Starknet account identity and returned-transaction checks), adopts the CSO EKU-1262 N-1 stop-condition tests, and addresses N-2..N-8 (§7, §8, §10, §12). The EKU-1261 revision closed CSO EKU-1233 T2-1..T2-3 and L-a..L-f and CFO EKU-1234 F1..F4. Production gate items L-4..L-7 and the L-c/L-d gate code are byte-unchanged in this revision.

- **Route:** Starknet Sepolia Governor → Starknet messaging → Ethereum Sepolia test `StarknetOwnerProxy` → `CCIPGovernanceSender` → CCIP → `CCIPOwnerExecutor` on BNB Chain testnet (97) and Monad testnet (10143). This is the Ethereum-hop fallback, not direct Starknet CCIP.
- **Revision:** the exact commit containing this file. The reviewed head SHA and this file's SHA-256 are recorded on the PR and the EKU-1261 issue, because a file cannot contain its own commit hash. The scope digest (§5) binds this file, the binding addendum and every tooling byte.

Evidence labels: **MOCKED** (local EVM with mocks), **REAL CODE ON FORK**, **IMPERSONATED** (an OffRamp pranked locally), **SIMULATED SETTLEMENT** (an L2→L1 message written into the real core with `vm.store`), **LOCAL SNFORGE**, **LOCAL ANVIL GUARD E2E** (the real signing path against local anvil forks with throwaway keys), and **FUTURE REAL (T2)** (only in the authorized funded run).

## 1. Revision and source-diff classification

| Item | Value |
|---|---|
| Base | `9287094` (EKU-1272) on `65e094e` (EKU-1268) on `5bab186` (EKU-1261) on `a483a79` (EKU-1232), stacked on PR #86 `2161f7a` |
| This revision's diff vs `9287094` | `script/t2/test/test_t2_guard.py` (new `FakeDeployRunner`, `DeployAccountTamperTest`) and this manifest only. `t2_guard.py` and every other file are byte-identical to `9287094`. |
| EKU-1272 diff vs `65e094e` | Test-only T2 tooling only: `script/t2/t2_guard.py`, `script/t2/test/test_t2_guard.py`, `script/t2/test/t2-local-e2e.sh`, `script/t2/t2-run.sh` (comment), `script/t2/binding/t2-binding.json` (UNBOUND template: new null `evm_keystore_sha256`), this manifest. The EKU-1268 diff vs `5bab186` was likewise T2 tooling only. **No** change under `l1_proxy/src`, `vendor`, `lib`, `foundry.toml`, `script/CCIPRouteGates.s.sol`, `script/t2/*.sol`, `script/t2/cairo`, `t2-limits.json`, `t2_budget.py`, `src/*.cairo` or `Scarb.*`. |
| Contract sources | **Unchanged.** The `l1_proxy/src`, `l1_proxy/vendor`, `l1_proxy/lib`, `foundry.toml`, `Scarb.toml`, `Scarb.lock` and `src/*.cairo` diff (other than `cfg(test)` files) against `2161f7a` is empty. |
| Production gate tooling (needs CSO review) | `script/CCIPRouteGates.s.sol`: **L-c** `requireDistinctHosts(AUDIT_RPC_URL_1, AUDIT_RPC_URL_2)` on the provider path; **L-d** `checkTransferReceipt` / `checkTransferTiming` (`AUDIT_MODE=post` needs `TRANSFER_TX_HASH` + `PRESIGN_AUDIT_TS`; `checkPostTransfer` needs `TRANSFER_TX_BLOCK` + `PRESIGN_AUDIT_TS`). L-4..L-7 code is untouched. |
| New test-only Cairo (needs exact-SHA review) | `l1_proxy/script/t2/cairo` (separate Scarb package `t2_voting_token`): `T2VotingToken`, fixed supply 1000e18 minted once in the constructor to the bound `t2-starknet` account. No mint, burn, owner, admin, upgrade or pause. Class hash `0x03c9587aec2a445af1ab5b8876287c7358cfa293bccaa8c20ddb54392bd0ff44`. 124 lines of snforge tests. |
| Test-only tooling, testnet only | `script/t2/`: `T2Config.sol`, `T2Route.s.sol`, `T2DummyTarget.sol`, `t2_guard.py` (new: the only signer), `t2_budget.py` (new) → `t2-limits.json`, `t2-run.sh`, `t2-starknet.sh`, `t2-evidence.sh`, `t2-fork-rehearsal.sh`, `binding/` (this manifest, the addendum template, the approval template), `test/test_t2_guard.py`, `test/t2-local-e2e.sh`. All refuse chains 1, 56 and 143. |
| Production runtime silently altered? | **No.** |

Toolchain: forge/cast 1.8.3, solc 0.8.28 via-IR, scarb/cairo 2.20.0, snforge/sncast 0.62.1, Python 3 stdlib only.

## 2. Refreshed lanes (official directory plus on-chain reads)

The directory API was read at `2026-10-10T07:03:22.953Z`:

- chains: `requestId 7ef42229-…`
- lanes: `205473b7-…`

The on-chain reads are pinned per chain (`logs/lane-snapshot.log`, reproduced by `lane-snapshot.sh`):

| Chain | Block (finalized) | Hash | Time (UTC) |
|---|---|---|---|
| Ethereum Sepolia 11155111 | 11882850 | `0x022534a48ea1cf7e85eb10a8a3099152379dae9fcb325b9ac621240dc75b7147` | 2026-10-10T06:51:00Z |
| BNB Chain testnet 97 | 135931335 | `0x0c16480e9d72cdf6dbfe67c45552baa8768cd328af52075518e399747ed991d6` | 2026-10-10T07:07:56Z |
| Monad testnet 10143 | 69761589 | `0x37166c7efa0296809e4650973486c44d190c4e8b53950e52cdd35caad88eac9d` | 2026-10-10T07:07:56Z |

| Role | Address | Version | Runtime keccak |
|---|---|---|---|
| Sepolia Router (selector 16015286601757825753) | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` | Router 1.2.0 (owner `0x903cA654…8De6`) | `0xb0b5a5a1…bfa5` |
| Sepolia OnRamp (to both 97 and 10143) | `0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777` | OnRamp 2.0.0 | `0xca80789e…cfdc6` |
| Sepolia FeeQuoter | `0x8632C3025FAFdD85A299211FD5838b5fBE2df816` | FeeQuoter 2.0.0 | – |
| BNB testnet Router (selector 13264668187771770619) | `0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f` | Router 1.2.0 (owner `0x804759c9…b722`) | `0x56d9a3cd…f0a6` |
| BNB testnet OffRamp from Sepolia | `0x32d4DD31a03e82FE7B1b8C9E5E6fa028B2fcA770` | **OffRamp 2.0.0** | `0x2b1cb151…815c` |
| BNB testnet legacy OffRamps from Sepolia (still registered) | `0xf1c128Fe52Ea78CcAAB407509292E61ce38C1523`, `0xB513523aee87f838e78b32d2Bacaaf2e94D9f0f9` | EVM2EVMOffRamp 1.2.0, 1.5.0 | `0x05e4b7a9…14df`, `0x7ac13d12…83dd` |
| Monad testnet Router (selector 2183018362218727504) | `0x5aD0A67f4Da0E8665a3fbf15E4215A780407Cf33` | Router 1.2.0 (owner `0x28A025d3…2A20`) | `0x56354695…e8d3` |
| Monad testnet OffRamp from Sepolia | `0x8C7676A0E7289Fe1ECb09d77a755E52AFd5eC471` | **OffRamp 2.0.0** | `0x3548d530…6384` |
| Monad testnet legacy OffRamp from Sepolia (still registered) | `0x5Dc49Ec54B92F7D493bC8126c0730DA74605cc00` | OffRamp 1.6.0 | `0x60ac74cf…46be` |
| Starknet Sepolia core (on Sepolia) | `0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057` | `StarkWare_Starknet_2026_12` | 19 state updates in the last 3000 Sepolia blocks (about one every 30 min) |

Lane configuration read on chain:

- `OnRamp.getDestChainConfig` to 97 is message number 15. Its `offRamp` field is `0x32d4…a770` and the base execution gas is 200000.
- To 10143 it is message number 14, with `offRamp` `0x8c76…c471` and base execution gas 400000.
- Both lanes use default CCV `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` and default executor `0x66f9E0738a4a6fe54aE62DEd00Ca1F72bDecc092`. Neither has lane-mandated CCVs.
- `FeeQuoter.getDestChainConfig`: both lanes are enabled with `maxDataBytes` 32000. `maxPerMsgGasLimit` is 15,000,000 for 97 and 8,000,000 for 10143.
- On both destination OffRamps, `getSourceChainConfig(Sepolia)` has `isEnabled` true. The allowed OnRamps are `0x8dcf…6777`, plus the older `0x181ac7dc…db5d` on Monad. `gasForCallExactCheck` is 5000.

Findings:

1. **Directory API caveat.** For lane A→B, the lanes API's `offRamp` field is the OffRamp located on chain A, which serves B→A. For example, `11155111_to_97` lists `0xc6A2…d0A1`, which is Sepolia's OffRamp. On-chain `Router.getOffRamps()` and `OnRamp.getDestChainConfig().offRamp` are authoritative, and the T2 scripts use them.
2. **Same shape as mainnet.** Router 1.2.0, OnRamp/OffRamp 2.0.0, and legacy OffRamps still registered (C12 trust delta). The sender's GenericExtraArgsV3 `0xa69dd4aa` message is accepted by the real Sepolia OnRamp. `getFee` and `ccipSend` both pass on the fork for both lanes (REAL CODE ON FORK).
3. **Low lane traffic.** There are about 15 messages ever on OnRamp 2.0.0 per lane. Delivery latency is therefore unproven. The stop conditions in §8 cover this.


**L-a (EKU-1261):** `checkLane` now requires the exact registered OffRamp set for the Sepolia selector, in Router order: 97 = {`0xf1c1…1523` 1.2.0, `0xB513…f0f9` 1.5.0, `0x32d4…a770` 2.0.0}, and 10143 = {`0x5Dc4…cc00` 1.6.0, `0x8C76…c471` 2.0.0}. Any addition, removal or reordering stops T2. Re-run `lane-snapshot.sh` immediately before step 2.

## 3. Contract set, constructors, dependency and address order

One fresh **T2 deployer** key is used on all three EVM chains. Its nonces are the address plan, asserted by every step and bound in the addendum (§5).

| # | Chain | Signer / nonce | Creates or calls | Exact constructor / calldata | Verified by |
|---|---|---|---|---|---|
| S0 | Starknet Sepolia | t2-starknet | OZ account deploy (address bound in the addendum) | – | account nonce = ledger |
| S1 | Starknet Sepolia | t2-starknet | declare `T2VotingToken` `0x03c9587a…ff44`, `governance::staker::Staker` `0x0244c221…dade`, `Governor` `0x044e2e3d…7401` (**same class as the production mainnet Governor**) | – | guard: the local build hashes to the pinned class before declare |
| S2 | Starknet Sepolia | t2-starknet | `T2VotingToken` via UDC, salt `0x1232`, unique | `[t2-starknet account]`. Fixed supply 1000e18, all to that account. **No faucet STRK voting.** | `sn-check`: class hash, `totalSupply` |
| S3 | Starknet Sepolia | t2-starknet | Staker via UDC, salt `0x1232`, unique | `[T2 token]` | class hash, `get_token == token` |
| S4 | Starknet Sepolia | t2-starknet | Governor via UDC, salt `0x1232`, unique | `[staker, 60, 600, 60, 1e18, 1e18, 60, 604800]` | class hash, `get_staker`, exact `get_config` tuple (L-b). Binds **`T2_L2_GOVERNOR`**. |
| S5 | Starknet Sepolia | t2-starknet | `token.approve(staker, 1000e18)`, `staker.stake_amount(self, 1000e18)`; wait ≥ 60 s | – | guard argv check |
| E0 | Sepolia | D nonce 0 | `StarknetOwnerProxy` test instance from the unchanged source | `(0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057, T2_L2_GOVERNOR)` | `t2CheckProxy` |
| B0–B1 | 97 | D 0–1 | 2 × `T2DummyTarget` | `(D)` | owner, address |
| B2 | 97 | D 2 | Safe 1.4.1 `createProxyWithNonce(SafeL2 0x29fc…C762, setup(owners[3], 2, 0, "", fallback 0xfd07…Ec99, 0, 0, 0), 1232)` | CREATE2, bound `safe_97` | owners, threshold 2, no modules, guard 0, fallback, singleton + codehash `0xb1f92697…81ff`, proxy keccak |
| B3 | 97 | D 3 | `CCIPOwnerExecutor` | `(0xE105…8F6f, 16015286601757825753, create(D,1), 3600, 86400, 604800, Safe97, [B0, B1])` | exact read-back incl. runtime keccak of a local build; `checkTiming(false)` |
| M0–M5 | 10143 | D 0–5 | 4 dummies, Safe (D 4), executor (D 5) | executor `(0x5aD0…Cf33, 16015286601757825753, create(D,1), 3600, 86400, 604800, Safe10143, [M0..M3])` | same |
| E1 | Sepolia | D 1, after B and M | `CCIPGovernanceSender` | `(0x0BF3…3A59, proxy, BOOTSTRAP, (13264668187771770619, 97, E97), (2183018362218727504, 10143, E10143), 1000000)` | both destinations re-verified over raw RPC first; `t2CheckSender` |
| B4–B5, M6–M9 | dests | D n+2… | `transferOwnership(executor)` on each dummy after that chain's proof executed | – | `t2TransferDummies` |

Executor delay is now **3600 s** (was 600 s), so the 2-of-3 test signers have a realistic window to cancel a DON-queued op. Window 86400 s and maxTtl 604800 s are unchanged. All three are bounded by `checkTiming(false)`, which refuses chains 1, 56 and 143. Production values stay 259200 / 1209600 / 2592000.

**Why a test voting token (T2-2).** With faucet STRK and a 1 STRK threshold and quorum, any third party could propose, vote, or consume the shared proxy nonce. `T2VotingToken` has no mint function, and its whole supply goes to `t2-starknet` at construction. Nobody else can ever hold voting weight, so nobody else can reach the threshold or quorum. The Governor stays the actual governance class with the exact T2 config. Third parties can still emit zero-weight events (for example a `vote`) or call permissionless functions. Any such event that is not from a ledger transaction **stops T2** (§8), which fails closed.

## 4. Runnable steps (FUTURE REAL unless marked)

EVM: `l1_proxy/script/t2/t2-run.sh <step>`. Starknet: `l1_proxy/script/t2/t2-starknet.sh <step>`. The default `T2_MODE=dryrun` only simulates or prints. With `T2_MODE=testnet`, every transaction goes through `t2_guard.py` (§7). There is no `--broadcast` path.

| Step | Command | Expected evidence |
|---|---|---|
| 0 | `t2-run.sh plan`, `lane-snapshot.sh`, `t2-run.sh digest` | Address binding; lane unchanged versus §2; computed digest (**not** an approval) |
| 1 | `t2-starknet.sh account-deploy`; `declare token`, `declare staker`, `declare governor`; `deploy token`, `deploy staker`, `deploy governor`; `stake`; `check` | Class hashes, supply, `get_token`, `get_staker` and `get_config` asserted |
| 2 | `proxy`, `dest 97`, `dest 10143`, `sender` | Exact post-checks over raw RPC |
| 3 | `verify bootstrap` | `T2 route VERIFIED` at finalized |
| 4 | **Pings (T2-1 split):** `ping-request 97 259200` (bootstrap) → `dispatch <payload>` (payer); then the same for 10143 | `Requested`, `Dispatched`, then the executor's **own `Pinged`**. OffRamp SUCCESS is not evidence. |
| 5 | **DeadlineTooFar FAILURE:** `ping-request 97 619200` → `dispatch` | No `Pinged`. After send + 4 h, `manualexec 97 <calldata-file>` (payer, guarded) gives `Pinged`. |
| 6 | `handoff` (bootstrap), `verify proxy` | `HandedOff`. eth_call: bootstrap `request` reverts `Unauthorized`; a second `handoff` reverts `AlreadyHandedOff`. |
| 7 | **P1:** `message 97 0 0 0 <dl>`, `message 10143 1 0 0 <dl>`; calls file `[2, call0, call1]`; `t2-starknet.sh propose`, `vote <id>`, `execute p1 <id> <file>` | Starknet tx hashes and the L2→L1 message hashes |
| 8 | `l1exec 97 0 0 0 <dl>`, `l1exec 10143 1 0 0 <dl>` (payer), then `dispatch` each | Refused until `l2ToL1Messages(hash) > 0`; proxy nonce 0→1→2 |
| 9 | After delivery + 3600 s: `execute 97 <proof>`, `execute 10143 <proof>` | Own `Queued`, then own `Executed` |
| 10 | `transfer 97`, `transfer 10143` (deployer) | `OwnershipTransferred(D → executor)` |
| 11 | **P2a:** `97/2/set42` + `97/3/set99`. **P2b:** `97/4/set43` + `10143/5/set42`. Each is propose → vote → `execute p2a` / `execute p2b`; then `l1exec` in nonce order and `dispatch` | Own `Queued` for each |
| 12 | **Safe cancellation of set99:** `canceltx 97 <hash(set99)>`; two test signers sign the safeTxHash offline (`cast wallet sign --no-hash`); `cancel 97 <hash>` (payer) | Safe `ExecutionSuccess` and own `Cancelled`; eth_call `execute(set99)` reverts `NotQueued` |
| 13 | After eta: `execute 97 <set43>`, `execute 10143 <set42>` (97 set42 is deliberately left to go stale) | `value() == 43` on 97, 42 on 10143 |
| 14 | Stale and replay rejections (eth_call, zero cost) | 97 `execute(set42)` `StaleOpId`, `NotQueued`, `NotPending`, `InvalidNonce`, `SkippedAlreadyExecutedMessage` |
| 15 | `t2-evidence.sh`; `t2-run.sh status`; post-run `CCIPRouteGates auditQueued` with `AUDIT_RPC_URL_1/2` on different hosts | Evidence per hop; ledger totals; no unknown live op |

**Changed from EKU-1232:**

- The 469-felt padded low-gas op (kind 2) is no longer sent for real. Its L2→L1 data alone costs about 23 STRK at the current Starknet Sepolia L1 gas price. `t2Dispatch` refuses kind 2 in testnet mode.
- The real out-of-gas FAILURE + manual execution is therefore **not reproduced on real CCIP**. Its evidence stays IMPERSONATED/local (CSO L-e). Real manual execution is still exercised by the DeadlineTooFar recovery (step 5).
- The Safe cancels a legitimately queued `set99` op instead of the padded op.
- P2 is split into two proposals (P2a and P2b). The CCIP message count stays 9: 3 pings, 2 proofs and 4 P2 messages.

**Local-only negatives** (cannot be produced on real CCIP without compromising it): forged sender, unregistered OffRamp, forged op through a legacy OffRamp, silent SUCCESS (M-1), and out-of-gas with a gas override (L-e). These are covered by `CCIPOwnerRouteFork`, `CCIPRouteGates*` and `T2RehearsalFork` (IMPERSONATED).

## 5. Roles, keys, binding and the two-stage authorization (T2-3, F4)

| Role | Chains | Funded (cap) | Purpose |
|---|---|---|---|
| `t2-deployer` | Sepolia, 97, 10143 | 0.06 ETH / 0.03 tBNB / 1.4 MON | Nonce plan (§3), dummy transfers |
| `t2-bootstrap` | Sepolia | 0.01 ETH | 3 ping requests and the handoff only |
| `t2-payer` | Sepolia, 97, 10143 | 0.18 ETH / 0.02 tBNB / 0.6 MON | Every dispatch fee, L1 execute, destination execute, Safe tx submission, manual OffRamp execution |
| `t2-safe-signer-a/b/c` | 97, 10143 | **0** (any nonce > 0 stops T2) | 2-of-3 test canceller; offline safeTxHash signatures only |
| `t2-starknet` | Starknet Sepolia | 50 STRK | Account: declare, deploy, stake, propose, vote, execute |

All six EVM roles must be pairwise distinct. None may be the company key, the production L1 proxy, a `0x1232…` or `0x1199…` placeholder, or a public anvil/hardhat key; the guard and `T2Route` both enforce this. The payer differs from the deployer, the bootstrap and every Safe owner (T2-1). Each signing step unlocks **exactly one** role keystore and refuses any planned transaction from another address.

**Two stages. Computing a digest or an address never approves anything.**

1. **Stage A: key preparation (a later human gate).** This approves only creating and storing the 7 testnet keys in a named 1Password vault. It approves no transaction and no faucet request. The keys are created as follows:
   - EVM roles: `op item create --vault <V> --category password --title t2-<role> --generate-password`, then `CAST_PASSWORD="$(op read …)" cast wallet new "$T2_KEYSTORE_DIR" t2-<role>.json`.
   - Starknet: `sncast --keystore $T2_KEYSTORE_DIR/t2-starknet.json --account <scratch>.json account create` (open_zeppelin). Its output and account file give the public identity: address, public key, account class hash and salt. `sha256sum t2-starknet.json` gives the keystore digest (a digest of the encrypted file, not key material).
   - Only public addresses, the Starknet public identity and the keystore digests leave the machine (`keys.json`: `starknet_public_key`, `starknet_account_class_hash`, `starknet_account_salt`, `starknet_keystore_sha256`, `evm_keystore_sha256: {deployer, bootstrap, payer}` = `sha256sum` of each encrypted EVM keystore file, plus `ledger_dir`, the absolute ledger directory on the single signing host). Safe owners sign only offline safeTxHash signatures, never through the guard, so they have no bound digest.
   - **Supported account (R2-D):** only class `0x05b4b537eaa2399e3aa99c4e2e0208ebd6c71bc1467938cd52c798c601e43564` (the OpenZeppelin account that installed sncast 0.62.1 `account create` uses; also a real Sepolia account class, test vector `0x12ba9a89…0d4b`), constructor `constructor(public_key)` → calldata `[public_key]`, deployed by `DEPLOY_ACCOUNT` (deployer address 0, salt unmodified). Any other class, constructor or deployer is refused, not guessed. `bind` refuses `keys.json` whose `starknet_account` is not the derived address before deriving anything from it.

   An approval record with `stage: key-preparation` is refused by every signing command.
2. **Binding.** `t2_guard.py bind --keys public-addresses.json` writes `binding/t2-binding.json` with status `BOUND`. It contains:
   - the roles, `op_vault`, Safe salt and Safe owners
   - the predicted proxy, sender, targets, Safes and executors (CREATE/CREATE2)
   - the token, staker and Governor addresses (UDC, unique, salt `0x1232`)
   - pinned class hashes and the Governor config
   - the stake amount and fee cap
   - the **Starknet account identity** (CFO R2): address, public key, account class hash, salt, type `open_zeppelin`, and the keystore sha256. **R2-D:** the address is recomputed from public data only (pure-Python Starknet Pedersen, no RPC, key or sncast): `pedersen_chain("STARKNET_CONTRACT_ADDRESS", 0, salt, class, pedersen_chain([public_key])) mod 2^251 − 256`. It must equal `roles.starknet_account`, `starknet.account` and the `starknet:SN_SEPOLIA` funding recipient, in `bind`, in every `check_binding` (every authorized command), and again in `sn` before the keystore is read, the password source is constructed, the descriptor is generated or any reservation is written
   - the **EVM keystore sha256** per signing role (CSO D-2): `evm_keystore_sha256` for exactly `deployer`, `bootstrap`, `payer`; all keystore digests (including Starknet) pairwise distinct
   - the **ledger directory** `ledger_dir` (N-3): one absolute, normalized path; `T2_LEDGER_DIR` is exported from it and a different pre-set value is refused, as is a different `T2_OP_VAULT`
   - **chain-qualified funding recipients** (`eip155:<cid>` or `starknet:SN_SEPOLIA`, with role, address and max). These are exactly the funded roles per chain, each at most its subcap; Safe owners can never be recipients.
   - the eligible free faucet sources (F4/N-7). `bind` and every signing command **refuse** an empty list, a source missing any of `url`, `eligibility`, `eligibility_checked_at`, `drip_max`, `login`, `region`, `operator`, a source with `paid` or `mainnet_prerequisite` not `false`, an `operator: agent` source without `automated_allowed: true`, a source for an unfunded chain, and a funded chain with zero or more than two sources.

   Before stage B, these checks are recorded in the addendum review: deployer nonce 0 on all three chains, no code at any predicted address, and Safe CREATE2 matching on 97 and 10143. The addendum is committed.
3. **Scope digest.** `t2_guard.py digest` = sha256 of `ekubo-t2-scope-v1`, manifest sha256, addendum sha256 and tooling sha256. The tooling sha256 covers every tracked byte under `l1_proxy/script`, `src`, `vendor`, `lib`, `foundry.toml`, `src/`, `Scarb.toml` and `Scarb.lock`, with submodules by commit. It is computed from a clean tree, and any uncommitted byte refuses.
4. **Stage B: final transaction authorization (human).** The approver names the exact scope digest, manifest, addendum and tooling hashes, approver, approval reference, and a window of at most 14 days. That record is saved verbatim as `binding/t2-approval.json` (`stage: final-transactions`). It is the only file excluded from the tooling digest, and it must be committed.

**What the guard enforces before any simulation or signing:**

- The recomputed digest and all three component hashes must equal the saved record, and the time must be inside its window.
- Identities, Safe salt, Governor felt, `T2_MAX_FEE_WEI` and `T2_STAKE` are exported **from the addendum**. A conflicting pre-set environment value is refused.
- `T2Route` re-checks every identity and prediction against `T2_BINDING_JSON`, whose sha256 must match.
- Changing any addendum byte, script byte or limit, or any role, address or nonce plan, changes the digest and refuses.

**Limit of the interlock.** The guard proves that the saved record names exactly this scope. It cannot prove that a human wrote the record. The operator must copy the record from the immutable Paperclip approval named in `approval_ref`, and reviewers compare the two.

**Funding sequence (F4).** Funding happens only after stage B, only to the bound recipients, only up to their caps, and only from the bound free sources. Every request and its result is recorded in the cumulative register in the ledger with `t2_guard.py faucet --chain <c> --role <r> --source <s> --status requested|received|denied [--ref <seq>] [--amount <n>] [--evidence <text>]` (stage-B approval required). The register refuses a second request for the same source, chain and recipient (a denied request still counts), any new request for a chain and role while one is pending, a request once the recipient holds its maximum, and a result that does not reference one open request. A receipt above the recipient's bound maximum is recorded truthfully and is an **incident that stops T2** (no reallocation, sweep or top-up). `t2-run.sh status` prints per chain and role: requests, pending, denied, received count and amount.

- Prohibited: mainnet balances or eligibility transfers, paid faucets or services, credential sharing, and top-ups or internal reallocations. Each of these has a cap of 0.
- At most one request per eligible source, chain and recipient, and at most two named sources per chain. There is no repeat while a request is pending or rate-limited.
- If free sources cannot cover the allocation, stop. Do not work around it.
- Source names to be validated for eligibility, drip size, login and region before binding:
  - Sepolia ETH: Google Cloud Web3 faucet, `faucets.chain.link`
  - tBNB: `faucets.chain.link` (the BNB Chain faucet's mainnet-balance rule is **not** satisfiable under these rules)
  - MON: `faucet.monad.xyz`
  - Starknet Sepolia STRK: `starknet-faucet.vercel.app`, Blast
- **Minimum human action.** Faucets that need a logged-in human, a captcha or a social account must be requested by a named human using their own access. The agent may request only from a source whose rules allow automated requests, after stage B. No operator is assumed.

## 6. Corrected budget (F2; generated by `t2_budget.py`, enforced from `t2-limits.json`)

`t2_budget.py` enumerates every transaction slot, including retry, failed, manual and incident slots, together with its **signed** per-transaction gas-limit maximum. The worst case assumes every slot is used, every attempt is charged its full signed limit at the gas-price ceiling (Monad charges the limit anyway), and every CCIP fee is at its 0.002 ETH maximum. Exact integer arithmetic. `--check` fails when the committed `t2-limits.json` differs from the schedule or when any role subcap or chain cap would be exceeded. In that case the schedule is revised; the caps are never raised.

The guard's `HARD` table repeats the CFO caps in code, and the limits file may only lower them. Test units have zero valuation and appear in no treasury figure. Real-money spend cap: **0**.

| chain | kind | role | planned | extra | gas max/tx | gas max total | worst native | slot |
|---|---|---|---:|---:|---:|---:|---:|---|
| 11155111 | deploy-proxy | deployer | 1 | 0 | 800,000 | 800,000 | 0.016 | E0 (a failure stops T2) |
| 11155111 | deploy-sender | deployer | 1 | 0 | 1,900,000 | 1,900,000 | 0.038 | E1 (a failure stops T2) |
| 11155111 | ping-request | bootstrap | 3 | 0 | 145,000 | 435,000 | 0.0087 | 2 pings + 1 DeadlineTooFar; **no retry** (bootstrap subcap) |
| 11155111 | handoff | bootstrap | 1 | 0 | 65,000 | 65,000 | 0.0013 | one-way |
| 11155111 | l1-execute | payer | 6 | 2 | 230,000 | 1,840,000 | 0.0368 | 2 P1 + 4 P2; 2 retries; no low-gas probe |
| 11155111 | dispatch | payer | 9 | 2 | 520,000 | 5,720,000 | 0.1364 | 9 messages + 2 failed-dispatch retries, incl. 11 × 0.002 fee |
| 97 | deploy-target | deployer | 2 | 0 | 700,000 | 1,400,000 | 0.0042 | B0–B1 |
| 97 | safe-create | deployer | 1 | 0 | 550,000 | 550,000 | 0.00165 | B2 |
| 97 | deploy-executor | deployer | 1 | 0 | 2,600,000 | 2,600,000 | 0.0078 | B3 |
| 97 | transfer | deployer | 2 | 1 | 80,000 | 240,000 | 0.00072 | 1 retry |
| 97 | execute | payer | 2 | 1 | 300,000 | 900,000 | 0.0027 | proof + set43 (set42 is left to go stale); 1 retry |
| 97 | safe-cancel | payer | 1 | 1 | 250,000 | 500,000 | 0.0015 | cancel set99; 1 incident cancel reserved |
| 97 | manual-exec | payer | 1 | 1 | 900,000 | 1,800,000 | 0.0054 | DeadlineTooFar recovery; 1 delivery-failure recovery |
| 10143 | deploy-target | deployer | 4 | 0 | 700,000 | 2,800,000 | 0.56 | M0–M3 |
| 10143 | safe-create | deployer | 1 | 0 | 550,000 | 550,000 | 0.11 | M4 |
| 10143 | deploy-executor | deployer | 1 | 0 | 2,600,000 | 2,600,000 | 0.52 | M5 |
| 10143 | transfer | deployer | 4 | 1 | 80,000 | 400,000 | 0.08 | 1 retry |
| 10143 | execute | payer | 2 | 1 | 300,000 | 900,000 | 0.18 | proof + set42; 1 retry |
| 10143 | safe-cancel | payer | 0 | 1 | 250,000 | 250,000 | 0.05 | incident cancel reserved |
| 10143 | manual-exec | payer | 0 | 1 | 900,000 | 900,000 | 0.18 | delivery-failure recovery reserved |

Worst case per role and chain (all slots used at the ceilings):

- Sepolia: deployer 0.054 / 0.06, bootstrap 0.01 / 0.01 (margin 0), payer 0.1732 / 0.18; chain 0.2372 / 0.25 (10.76M gas)
- BNB testnet: deployer 0.01437 / 0.03, payer 0.0096 / 0.02; chain 0.02397 / 0.05 (7.99M gas)
- Monad testnet: deployer 1.27 / 1.4, payer 0.41 / 0.6; chain 1.68 / 2 (8.4M gas, limit-charged)
- The test-token deployment is on Starknet only; it adds no EVM slot.

**Counts** (old → new): EVM ≤ 56 → **55** attempts, of which 43 are planned: per chain (`attempts_max`) Sepolia **25** (21 planned), BNB testnet **14** (10), Monad testnet **16** (12). (CFO EKU-1269 correction of an earlier narrative that said 23/18; the committed limits never changed.) Successful CCIP messages stay at ≤ 9, and dispatch attempts drop from ≤ 12 to ≤ 11. Proxy executions drop from ≤ 10 to ≤ 8, because the low-gas probe is gone.

Starknet goes from ≤ 16 to **18 planned + 2 retries = 20 attempts**. The increase is explicit and comes from two sources:

- the test-token declare and deploy (T2-2)
- splitting P2 into two proposals, which removes the ~23 STRK padded message

**Starknet (fri; 1 STRK = 1e18).** Each kind has a signed `--max-fee`, which is also the per-transaction ceiling (≤ 10 STRK). The sum of planned max fees is 39.4 STRK, against a **48 STRK** aggregate fee cap. Every attempt reserves its max fee, and a reservation that does not fit the remaining aggregate is refused before signing. At most 2 retries are allowed in total, each within its kind's attempt cap.

The 2 STRK non-fee reserve is kept as a balance margin. No STRK is staked any more; the staked asset is the zero-value test token. That gives 48 + 2 ≤ 50.

| kind | planned | attempts max | max fee/tx (STRK) |
|---|---:|---:|---:|
| account-deploy | 1 | 2 | 1 |
| declare-token / declare-staker / declare-governor | 1 each | 2 each | 2 / 4 / 5 |
| deploy-token / deploy-staker / deploy-governor | 1 each | 2 each | 1 each |
| approve / stake | 1 each | 2 each | 0.5 each |
| propose / vote | 3 each | 4 each | 0.5 / 0.3 |
| execute-p1 / execute-p2a / execute-p2b | 1 each | 2 each | 7 each |

These Starknet fee bounds are estimates: L2→L1 message L1 gas is measured by snforge, and the Starknet Sepolia L1 gas price is from 2026-10-10. Before every send, the guard takes a fresh `--dry-run` estimate (after the durable reservation, §7). Any estimate above the kind's max refuses, and T2 stops and is revised; nothing is raised.

**Budget stop, not a completion guarantee.** The caps are ceilings that the guard enforces; they do not guarantee that every planned step fits. Planned Starknet max fees are 39.4 STRK; the two largest retry slots need 14 STRK more, so planned + two largest retries = 53.4 STRK > the 48 STRK aggregate. If retries are needed, the aggregate precheck (and every EVM role/chain cap likewise) **refuses and T2 stops incomplete**; caps, acquisitions and the schedule are never raised to finish it. Bootstrap has margin 0 on Sepolia. An in-process refused signing attempt (`void`) still consumes its attempt slot. A stop before completion is an acceptable T2 outcome, reported as such.

## 7. Durable attempt ledger and pre-sign enforcement (F1, CFO R1/R2)

**Ledger file.** `<ledger_dir>/ledger-<sha256(roles)[:16]>.jsonl`, where `ledger_dir` comes **only** from the bound addendum (N-3; mode 0700/0600). `T2_LEDGER_DIR` is a bound environment value: a different pre-set value refuses, so two runners on the signing host cannot select separate ledgers or locks. The ledger is held under an exclusive non-blocking `flock`, so a second runner is refused. Records are append-only. Each line carries `seq` and `prev` (the sha256 of the previous line), is written with `O_APPEND`, and is followed by an fsync of both the file and the directory. On load, a torn final line, a broken chain or a broken sequence refuses. Limit: `flock` is per host; runners on different hosts are bounded only by the on-chain nonce anchoring (at most one transaction in a race, after which both refuse).

**Record types:**

| type | fields |
|---|---|
| `reserve` | Written **before any signer runs**. `chain`, `role`, `from`, `kind`, `step`, `nonce`, `attempt` (kind attempt number), `max_cost` (= gas × max fee + value, or the Starknet kind max fee), `hash: ""`. EVM adds the unsigned intent `gas`, `max_fee`, `priority`, `value`, `to`, `input_sha256` and `intent_sha256`; Starknet adds `argv_sha256`, `expect` (the exact transaction the kind may produce), `descriptor_sha256`, `keystore_sha256` |
| `signed` | EVM only, written after the signed bytes were verified against the reservation and **before** publishing: `ref`, `hash`, `raw`, `raw_sha256` |
| `sn-bounds` | Starknet only, after the dry-run and before the real send: `ref`, explicit `bounds` (L1 gas, L2 gas, L1 data gas: max amount and max price), `tip: 0`, `max_liability` (≤ the reservation) |
| `sn-sent` | Starknet only: `ref`, `hash` returned by sncast |
| `outcome` | `ref`, `chain`, `status`, `gas_used`, `block`, `cost` (receipt actual; on Monad the gas limit), `dispatched` (CCIP payload ids), `contract` |
| `void` | `ref`, `reason`. Only (a) the same nonce was mined by another *ledger* transaction, or (b) an **in-process** refusal by the signer or the signed-field comparison (EVM), or by the sncast dry-run or the estimate check (Starknet), where nothing was published and the bytes were discarded. A void attempt still counts against the kind and chain attempt caps. |
| `incident` | `ref`, `reason`: a returned Starknet transaction that does not match its reservation, a malformed receipt, or a faucet receipt above its maximum. Any incident is a permanent stop. |
| `faucet` | the cumulative faucet register (§5) |
| `watch` | `chain`, `from`, `to` (log ranges already checked for unknown events) |

**Order of every EVM signing step** (`t2-run.sh` → `t2_guard.py`):

1. `env`: scope and approval are checked, and the bound environment is exported.
2. `preflight` refuses on any incident or fee overrun, any open reservation, any RPC whose `eth_chainId` differs, and any role nonce that differs from the ledger's mined count.
3. A fresh forge simulation becomes the plan.
4. `send` starts with `reconcile` (chain id of **every** EVM RPC, receipts for open reservations, nonce equality, void only for ledger twins; an unlinked reservation refuses permanently, below).
5. Then the stop watches run (§8), again checking the chain id of every EVM and the Starknet RPC.
6. Every planned transaction is classified into exactly one allowed kind for this step, and its broadcaster must be the step's single role. A wrong broadcaster refuses before any reservation or signer.
7. **Per transaction, before anything is reserved:**
   - latest nonce == pending nonce == plan nonce == ledger mined count
   - fresh base fee ≤ ceiling; max fee = ceiling; priority clipped
   - gas limit ≤ kind max; value ≤ kind max (only `dispatch` carries value, ≤ 0.002 ETH)
   - kind attempt cap and chain attempt cap; no incident, no fee overrun
   - no open reservation
   - **spent + reserved + candidate max cost ≤ role subcap and ≤ chain cap**
   - for dispatch: messages + 1 ≤ 9 and fees ≤ 0.018 ETH
8. **The unsigned intent and its maximum liability are appended and fsync'd (`reserve`) BEFORE the signer is invoked** (CFO R1). No code path signs and then reserves.
9. `cast mktx` signs with the role keystore. **D-2:** before step 7's reservation, the keystore file is read **once**, its sha256 must equal the bound `evm_keystore_sha256[role]` (a missing digest, missing file or different byte refuses, with no reservation and no password read), and those frozen bytes are what cast decrypts, through an anonymous memfd (`--keystore /dev/fd/N`), so a path swap after the check changes nothing. The password goes through another anonymous memfd, never argv, env or disk. cast runs with a minimal allowlisted environment (D-3). If cast does not return within its timeout, the child is killed and reaped and the reservation stays unlinked (permanent stop, N-2). `cast decode-transaction` decodes the signed bytes, and every field must equal the reserved intent: signer, chain, nonce, to, value, input, gas, maxFee, priority, type 2, no access list. A refusal here is in-process: the bytes are discarded unpublished and the reservation is closed as `void` (attempt still counted).
10. The verified signed bytes are appended and fsync'd (`signed`), **then** `cast publish` is called. The step waits for the receipt and records the outcome. A revert is counted at its real cost, and T2 stops.

**Crash or stop at each boundary** (local evidence in §11):

| Boundary | Ledger state | What happens next |
|---|---|---|
| after `reserve`, before or **during** signing | open, unlinked, counted at its maximum | Every later attempt refuses ("unknown outcome"); `reconcile` refuses **permanently** (N-2) |
| after signing, before the `signed` link | open, unlinked | same: permanent stop. A signature may exist; whether it was published cannot be reconstructed |
| a signer error that is not a refusal (e.g. timeout) | open, unlinked | same: permanent stop |
| after the `signed` link, before or after publish | open, linked | `reconcile` reads the receipt; `reconcile --republish` re-sends the **identical** signed bytes (same hash, same reservation, no new slot or liability) |
| linked but dropped and never mined, nonce unchanged | open, linked | stays reserved; if republishing cannot land it, T2 stops permanently (N-2) |

**N-2 (accepted conservative stop).** An unlinked or hashless reservation, and a linked transaction that is dropped and cannot be landed by republishing the same bytes, are **never released**. An absent transaction or an unchanged nonce is not treated as proof that nothing was signed or sent. T2 then stops permanently: resuming requires a code change, a new exact-SHA review and a new approval. This revision requests **no** void or recovery authority for these cases.

**Starknet** (`t2_guard.py sn --kind <k>`, CFO R2):

1. The Starknet Sepolia chain id is checked, and the exact argv shape for the kind (target, function, calldata, class hash, salt, unique). Every proposal and execute call must be `send_message_to_l1` on the T2 Governor to the bound proxy. Signer, fee, nonce, account, keystore, network, wait, dry-run and json options are refused if the caller supplies them.
2. **Identity, before any password or key access:** first (R2-D) the bound address must equal the `DEPLOY_ACCOUNT` address derived from the pinned class, the bound salt and constructor `[public key]` (and so must `starknet.account` and the funding recipient); a mismatch, an unsupported class or a missing field refuses before the keystore is read, the password source is constructed or sncast runs (no dry-run, no account deploy, no ledger record). Then the keystore file's sha256 must equal the bound `keystore_sha256`. For every kind except `account-deploy`, the on-chain class hash of the bound account must equal the bound account class hash, and its `get_public_key` must equal the bound public key; `account-deploy` requires that the bound address has no code yet. The sncast account descriptor is **generated from the bound identity** (address, public key, class hash, salt): an operator-supplied account file is never read, so it cannot be substituted. The keystore bytes and the descriptor are frozen in anonymous memfds that sncast reads through `/dev/fd`.
3. reconcile (chain id; open reservations are credited only as in step 8) and the account nonce are checked against the ledger; every token, Staker and Governor event must come from a ledger transaction.
4. The attempt, retry and 48 STRK aggregate checks apply to the kind's max fee. **The reservation (kind max, nonce, expected transaction) is fsync'd before sncast runs at all**, dry-run included.
5. `sncast --dry-run` (the first password access; it signs only a query-version transaction that the network never executes). The guard derives explicit resource bounds from the fresh estimate, with the first margin whose maximum liability fits the reservation (amount × 1.5 and price × 2, then smaller, down to the bare estimate); an estimate above the kind max refuses. A dry-run failure or an estimate refusal closes the reservation as `void`.
6. The bounds and their maximum liability are fsync'd (`sn-bounds`), then sncast sends with exactly those bounds, `--tip 0` and `--nonce` (account deploy has no nonce option; its nonce is checked in step 8). Installed sncast 0.62.1 signs exactly the given bounds and skips its own estimate (§11).
7. The returned hash is linked (`sn-sent`). A crash or sncast failure before the link leaves an unlinked reservation: permanent stop (N-2).
8. **Before crediting**, the receipt must be final (`ACCEPTED_ON_L2` or `ACCEPTED_ON_L1`; anything else stays unknown and reserved), and the transaction returned by the chain must match the reservation: type (`INVOKE`, `DECLARE` or `DEPLOY_ACCOUNT`) and version 3; nonce; sender (or, for account deploy, class hash, salt, constructor calldata = public key, and the receipt's contract address); the exact `__execute__` calldata (the single call, or the UDC `deployContract` call with class hash, salt, unique and constructor calldata) or the pinned declared class; resource bounds equal to the reserved `sn-bounds` record (no record: not credited); tip 0; no paymaster or account-deployment data; nonce and fee data-availability modes `L1` (D-3); signed maximum liability ≤ the reservation. The receipt fee must be in FRI. Any mismatch or missing field is an `incident`: the transaction is **not credited**, the reservation stays open at its maximum, and T2 stops permanently. The chain is identified by the checked RPC chain id (the guard does not recompute the transaction hash).
9. The outcome is recorded at the actual fee. An actual fee above the reservation is recorded truthfully and **stops T2** (N-5) at that point and on every later command. Deployments are re-checked (L-b).

**JSON-RPC errors (N-6).** Only the exact Starknet error code 20 (`CONTRACT_NOT_FOUND`) means "no account yet, nonce 0" or "no code"; only code 29 (`TXN_HASH_NOT_FOUND`) means "unknown transaction". Any other error refuses; error text is never matched.

## 8. Stop conditions (enforced before every attempt unless marked procedural)

- Any read-back, nonce, address, runtime keccak, class hash or config mismatch.
- A lane change versus §2, including a registered OffRamp set that differs from the pinned set (**L-a**: 97 = {1.2.0, 1.5.0, 2.0.0}, 10143 = {1.6.0, 2.0.0}, exact and in order).
- A gas price above its ceiling; a fee estimate above the kind max; a cap or count that would be exceeded; an open reservation; a nonce or ledger mismatch; a locked or tampered ledger; an altered scope byte; an expired approval.
- Any RPC (every EVM chain and Starknet, not only the sending chain) reporting another chain id (N-4); any JSON-RPC error other than the exact codes in §7 (N-6).
- An unlinked or unresolvable reservation (N-2, permanent); an `incident` (returned Starknet transaction that does not match its reservation, malformed receipt, faucet receipt above its maximum); an actual fee above its reservation (N-5). These persist: every later command refuses.
- A Starknet keystore whose sha256 differs from the binding, or an on-chain account class or public key that differs, or a bound Starknet address that is not the derived `DEPLOY_ACCOUNT` address (R2-D), or an EVM keystore whose sha256 differs from `evm_keystore_sha256` (D-2) (all refused before any password access).
- **T2-2:**
  - any executor `Pinged`/`Queued` for a payload id this ledger did not dispatch (the Safe cancels, T2 stops, CSO is notified)
  - any log on the proxy, sender, Safe, dummies or executor from a transaction outside the ledger (unknown `Requested`, message or call)
  - a proxy `currentNonce` different from the ledger's successful L1 executions (an unknown L2 message consumed a nonce)
  - any Safe signer nonce > 0
  - any T2 token, Staker or Governor event from a transaction outside the ledger (third-party proposal, vote or stake)
- Procedural:
  - no own executor event 6 h after `Dispatched` (3 h for pings): investigate, and **never** dispatch beyond the 9-message cap
  - Starknet settlement over 24 h, or a message deadline within 12 h of expiry
  - suspected key exposure
  - if the DON does **not** fail a message the plan expects to fail, record it as "not reproduced" (L-e)

## 9. Concrete T2 authorization scope (proposed; two stages)

> **Stage A (key preparation):** create 7 testnet-only keys (`t2-deployer`, `t2-bootstrap`, `t2-payer`, `t2-safe-signer-a/b/c`, `t2-starknet`) as encrypted keystores, with passwords in 1Password vault `<V>`. Publish only their public addresses, the Starknet public identity (public key, account class hash, salt) and the keystore sha256, then validate the free faucet sources, run `t2_guard.py bind` and commit the addendum. No funding, no faucet request, no transaction.
>
> **Stage B (final transactions):** for scope digest `<t2_guard.py digest>` (manifest `<sha256>`, addendum `<sha256>`, tooling `<sha256>`) at head `<sha>`:
>
> - free-faucet funding of the bound recipients from the bound free sources, up to 0.25 Sepolia ETH, 0.05 tBNB, 2 MON and 50 STRK
> - on 11155111, 97, 10143 and Starknet Sepolia only, the transactions in §3 and §4 within the §6 limits, at most 9 CCIP messages, under §8
> - dummy targets only
>
> **Excludes:** any production chain, address, key, Safe, signer or on-call; any mainnet transaction, merge or deployment; T3–T6; paid provisioning; top-ups. **Expires** at most 14 days after approval.

## 10. Production gate lows

L-4..L-7 are unchanged from EKU-1218/1233 and are still enforced and tested (`requireTransferClean`, `reconcileSecondSource`, singleton codehash, Monad chunk and freshness).

New in this revision:

| Low | Enforcement | Test |
|---|---|---|
| L-c | The provider path requires `AUDIT_RPC_URL_1` and `AUDIT_RPC_URL_2` on **different hosts** (`requireDistinctHosts`; case, scheme, userinfo, port, path and query are ignored). The runbook passes `AUDIT_RPC_URL_1` as the fork URL. | `test_Lc_distinctHosts`; `test_Lc_monitorSuperset_rejected` (a superset monitor export, or one with a duplicate, fails on the count check) |
| L-d | `AUDIT_MODE=post` requires `TRANSFER_TX_HASH` and `PRESIGN_AUDIT_TS`. `checkTransferReceipt` rolls the fork to the transaction, requires its block == `TRANSFER_TX_BLOCK` and its timestamp ∈ [presign, presign + 72 h], then restores the fork. `checkPostTransfer` additionally requires each `OwnershipTransferred(company, executor)` log to be in `TRANSFER_TX_BLOCK`, and applies the same receipt check. | `test_Ld_transferTiming`. The fork roll is exercised only on a real transfer: **not yet fork-tested**. |
| L-e | Real out-of-gas manual execution is no longer attempted; evidence stays IMPERSONATED (§4). | – |
| L-f | sncast still receives `KEYSTORE_PASSWORD` in its own process environment. This is acceptable for testnet-only keys and **must not** be reused for production. EVM signing now uses a memfd. Since EKU-1272 (D-3) both cast and sncast get a minimal allowlisted environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_*`, `TMPDIR`, `TERM`, `SCARB_*`, `MISE_*`, `XDG_*`, plus `KEYSTORE_PASSWORD` for sncast only), so RPC, wallet and 1Password variables of the parent never reach them. | `EvmKeystoreBindingTest`, `StarknetIdentityTest` |

**D-3 residuals (CSO EKU-1270; testnet only, no recovery authority added):**

- **Timeout child.** Contained: a `cast mktx` that exceeds its timeout is killed and reaped. Remaining risk: a signature may exist in the killed child's memory or output pipe; the reservation stays unlinked, so T2 stops permanently (N-2) and nothing is released. `sncast` has no guard timeout: a hung sncast blocks the runner (the ledger lock is held) until the operator kills it, which leaves the same unlinked, never-released reservation. No liability beyond the reserved maximum.
- **Minimal environment.** Contained in code (above). Remaining risk: `PATH`, `HOME` and `SCARB_*`/`MISE_*` still select the executables and the scarb/sncast global config, and sncast still sees `KEYSTORE_PASSWORD` (L-f). The signing host must have a trusted `PATH` and home; a hostile working-directory `snfoundry.toml` was shown not to redirect (CSO EKU-1270 probe).
- **DA modes.** Contained: a returned Starknet transaction with nonce or fee data-availability mode other than `L1` is an incident. There was no liability impact either way (fees are bounded by the explicit resource bounds).

**Production runbook items carried forward (CSO N-7, N-8; procedural, not enforced by this tooling):**

- **N-7 provider, not only host.** `requireDistinctHosts` proves only that `AUDIT_RPC_URL_1` and `AUDIT_RPC_URL_2` have different hostnames. The final production manifest must name the **operator** of each endpoint and show they are independent providers (not two hostnames, gateways or resellers of the same backend), with that evidence attached.
- **N-7 fork URL.** `AUDIT_RPC_URL_1` is a declared value; the gate cannot prove it is the `--fork-url` forge used. The production runbook runs the gate through one wrapper that passes `--fork-url "$AUDIT_RPC_URL_1"` from the same variable, records the full command line, and the reviewer checks `eth_chainId` and the latest block hash of the fork against both endpoints at the audit block.
- **N-8 approval origin.** Before the first T2 signing (and in the production manifest for its approval record), CSO or CTO compares the committed `binding/t2-approval.json` byte for byte with the record in the immutable Paperclip approval named in `approval_ref` and posts both sha256 values. The guard proves only that the record names this exact scope; a recomputed digest is not an approval.
- **F4 before stage B.** No stage-B request without a BOUND addendum whose faucet sources pass the checks in §5 (eligibility evidence, operator, free, no mainnet prerequisite, one or two per funded chain), and without the empty cumulative register that will record requests, pending, denied and received per chain and role. Real-money, paid-service, mainnet and credential-sharing caps stay **0**; acquisition and production caps are unchanged.

T6 command per transfer:

```
AUDIT_RPC_URL_1=<primary> AUDIT_RPC_URL_2=<other host> KNOWN_PAYLOAD_HASHES=<proof> \
  forge script CCIPRouteGates --sig "checkDirectTransfer()" --fork-url "$AUDIT_RPC_URL_1"
```

Afterwards, run again with `AUDIT_MODE=post TRANSFER_TX_HASH=<h> TRANSFER_TX_BLOCK=<n> PRESIGN_AUDIT_TS=<printed audit ts>` at block n−1. Production T3–T6 remain separate and unauthorized.

## 11. Reproduction (independent re-review)

```sh
cd l1_proxy
forge test                                           # unit + gate tests (fork suites skip without RPC env)
python3 script/t2/test/test_t2_guard.py -v           # guard/budget unit, negative, property, crash and identity tests (no RPC,
                                                     # no real key; SncastCompatTest: installed sncast + local fake node +
                                                     # throwaway keystore; T2_SKIP_SNCAST=1 skips it)
python3 script/t2/t2_budget.py --check && python3 script/t2/t2_budget.py
(cd script/t2/cairo && snforge test)                 # T2VotingToken: fixed supply, no mint, transfers/allowances
(cd .. && snforge test t2_)                          # Governor emits the exact L2->L1 felts
SEPOLIA_FORK_URL=https://sepolia.gateway.tenderly.co BNB_TESTNET_FORK_URL=https://bsc-testnet-rpc.publicnode.com \
MONAD_TESTNET_FORK_URL=https://testnet-rpc.monad.xyz STARKNET_SEPOLIA_RPC_URL=https://starknet-sepolia-rpc.publicnode.com \
  script/t2/test/t2-local-e2e.sh /tmp/t2-e2e        # LOCAL ANVIL GUARD E2E (throwaway keys, local balances only)
SEPOLIA_RPC_URL=… BNB_TESTNET_RPC_URL=… MONAD_TESTNET_RPC_URL=… script/t2/t2-fork-rehearsal.sh /tmp/t2-fork
```

The local e2e drives the real `t2-run.sh` → forge → `t2_guard.py` → `cast mktx`/`publish` path against three anvil forks, with six throwaway keystores and a test-only `op` shim. It checks:

- no approval, a key-preparation stage, an expired approval and a window over 14 days are all refused, and nonce 0 is preserved
- the deployer deploys the proxy, both destinations and the sender, each with a post-check
- one uncommitted byte, a pre-set `T2_PAYER` and a raised `T2_MAX_FEE_WEI` are refused
- `bind` refuses keys whose Starknet address is not derived from their salt (R2-D)
- **the payer keystore under the bootstrap role is refused by its bound sha256 (D-2) before any reservation or password read, and nothing is published**; the bound bootstrap keystore with a wrong password is reserved before signing and closed as `void` (attempt counted)
- a concurrent runner and a base fee above the ceiling are refused
- **two-role ping**: the bootstrap requests and the payer dispatches
- crash after the durable signed link and before publish (`T2_FAULT=linked`): the next attempt is refused, then `reconcile --republish` sends the identical bytes and the flow continues
- the real ledger: every EVM reservation was written without a hash and precedes its `signed` link
- a deleted ledger is refused
- the handoff succeeds; a bootstrap request after the handoff is refused
- an out-of-band payer transaction is refused
- an edited binding with the old approval is refused

**Boundary-specific evidence for this revision (EKU-1268).** `test_t2_guard.py` adds, all key-free:

| Requirement | Test (class) | What it proves |
|---|---|---|
| R1 reserve before sign | `PreSignReservationTest` | The fake signer reads the ledger **from disk** when it is called: the last record is an unlinked `reserve` of exactly this chain, role, nonce and max cost. Order is `reserve`, `signed`, `outcome`. A precheck or broadcaster refusal reaches no signer and writes nothing. A signed-field refusal is `void`, unpublished, still counted. A signer error that is not a refusal leaves the slot unresolved. |
| R1 crash boundaries | `CrashBoundaryTest` | A child process exits with `os._exit` (no cleanup) **during signing**, **after signing before the link**, and after the link. The reservation is durable at its maximum; the next attempt refuses before any signer call; reconcile refuses permanently for the first two; the third republishes the identical bytes with no new slot. Starknet: exits after the reservation, after the bounds, during the send and after sncast returned; all leave a durable unlinked reservation and a permanent stop, with no sncast call. |
| concurrency | `ConcurrencyTest`, e2e | A second process cannot take the ledger lock. |
| N-1 stop conditions | `StopConditionTest` (adopted from CSO `cso_watch_test.py`) | Unknown payload (`Queued` and `Pinged`), foreign transaction logs (sender, Safe), Safe signer nonce, proxy `currentNonce` (mismatch and match), Starknet foreign event (and own event passes), Starknet nonce mismatch, clean cases. |
| N-4 | `StopConditionTest`, `PreSignReservationTest` | A wrong `eth_chainId` on a non-sending chain refuses in reconcile and watch; a wrong Starknet chain id refuses in reconcile and watch; the sending chain refuses before the signer. |
| R2 identity | `StarknetIdentityTest` | Keystore sha256, on-chain class and public key refusals; account-deploy needs no code; the descriptor is generated from the binding; the runner passes the frozen bytes through `/dev/fd` and reads the password only inside `run()`. |
| R2 returned transaction, N-5 | `StarknetSendTest` | Wrong sender, nonce, payload, resource bounds, tip, version, fee unit, and each missing field: not credited, incident, reservation kept at max, and the next command refuses with no sncast call. Actual fee above the reservation: recorded at the actual fee, then every Starknet and EVM precheck refuses. Estimate above the cap: dry-run only, `void`. sncast is never run before the reservation. |
| N-6 | `StarknetRpcErrorTest` | Only code 20 gives nonce 0 / no code; code 21, 24, -32603 and a bare "20" refuse; only code 29 means an unknown transaction. |
| N-3, F4/N-7 | `LedgerDirTest`, `FaucetBindingTest`, `FaucetRegisterTest` | The ledger directory comes from the binding even with `T2_LEDGER_DIR` set; `T2_LEDGER_DIR`/`T2_OP_VAULT` overrides refuse; bad paths refuse. An empty or incomplete faucet source list refuses (the committed UNBOUND template has none and is refused); the register's one-request, pending, denied and over-maximum rules. |
| installed sncast | `SncastCompatTest` | The real `Sncast` runner and `sn_send` drive **installed sncast 0.62.1** against a local fake JSON-RPC node with a throwaway keystore created for the test: account deploy, vote and UDC deploy. sncast signs exactly the guard's bounds and tip 0, uses `--nonce`, builds the calldata `sn_expected` predicts, and the guard's on-chain verification accepts it; a wrong password fails at the dry-run (`void`, nothing sent). sncast `account deploy` itself refuses a keystore whose key does not match the descriptor public key. Declare is not exercised (it needs a local build against a node). |

**Boundary-specific evidence for this revision (EKU-1272).** All key-free (the only keys are throwaway local fixtures, deleted with their temp dirs):

| Requirement | Test (class) | What it proves |
|---|---|---|
| R2-D vectors | `StarknetAddressDerivationTest` | Pedersen matches the starkware vector; the derivation reproduces three real Starknet Sepolia `DEPLOY_ACCOUNT` receipts (`0x12ba9a89…0d4b` with the pinned class and an 8-byte sncast-style salt, plus two other account classes with single- and multi-felt constructors) and the address installed sncast printed for `account create`; the two other classes are refused, not guessed. |
| R2-D boundaries | `StarknetAddressDerivationTest`, `SnRunPrePasswordTest`, `SncastCompatTest` | 18 mismatches (all address fields, each field alone, the funding recipient, salt 0x1/0x2 as in the CFO probe, public key, unsupported/arbitrary class, an address from another constructor or a non-zero deployer, each missing field) are refused by `check_binding`, `check_sn_account_binding`, `sn_check_identity`, `sn_account_descriptor` and `sn_send` (no reservation, no sncast). Through `sn_run` (the `sn` command after authorization) each refuses with **zero password-source constructions, zero password reads, zero sncast runs (no dry-run, no account deploy) and no ledger record**; the valid identity reaches the password only after the reservation. `bind` refuses inconsistent keys before deriving token/staker/Governor addresses. Installed sncast's own `account create` address equals the derivation. |
| D-1 | `DeltaCoverageTest` | One killing test per CSO survivor: Starknet linked-but-unincluded send blocks the next send (nonce alone would not); a non-final receipt (`RECEIVED`, `PRE_CONFIRMED`, `CANDIDATE`, none) is not credited; account-deployment data on INVOKE; no `sn-bounds` record is not credited; an EVM publish failure keeps the reservation open at its maximum (next attempt refused, absent receipt never releases it); a twin void needs the twin's receipt; a receipt with another `from` or hash is refused; pending ≠ latest nonce refuses before any signer; a faucet result without one matching open request is refused. |
| D-2 | `EvmKeystoreBindingTest` | The binding needs distinct digests for exactly the three signing roles (UNBOUND template has nulls); substituted bytes, one extra byte, a missing file or no bound digest refuse before any reservation, password read or cast run; the frozen bytes are signed even if the file is swapped after the check; real `cast mktx` signs from the memfd keystore (throwaway key). |
| D-3 | `EvmKeystoreBindingTest`, `StarknetIdentityTest`, `DeltaCoverageTest` | cast and sncast children see only the allowlisted environment; a hung signer child is killed and reaped and the slot stays unlinked (permanent stop); a non-`L1` DA mode is an incident. |

**Boundary-specific evidence for this revision (EKU-1280, CSO EKU-1274 E-1).** Key-free (fixture identity, fake RPC, fake runner, fake sncast executable):

| Requirement | Test (class) | What it proves |
|---|---|---|
| E-1 returned `DEPLOY_ACCOUNT` | `DeployAccountTamperTest` | Through the full `sn_send` `account-deploy` path with a key-free `FakeDeployRunner` (dry-run, explicit bounds, no `--nonce`, password read once per run as in `Sncast`): a returned tx with another `class_hash`, `contract_address_salt` or `constructor_calldata`, or a receipt with another `contract_address`, persists exactly `reserve`, `sn-bounds`, `sn-sent`, `incident`; no `outcome` or `void`; the reservation stays open at the `account-deploy` maximum. The next `sn_send` refuses with zero runner calls and zero password reads, and the next `sn` command through `sn_run` with the real `Sncast` runner (account-deploy and vote) refuses with zero password reads, zero sncast runs and no further ledger record. A clean control on the same path is credited (`reserve`, `sn-bounds`, `sn-sent`, `outcome`, no incident) and its reserved `expect` carries all four fields. |

Mutation: `cso_1274_mutants.py` (CSO EKU-1274, 18; the four E-1 survivors are now killed) is kept with the EKU-1280 evidence. `cso_mutants.py` (CSO EKU-1262, 18), `presign_mutants.py` (EKU-1268, 35), `cso_delta_mutants.py` (CSO EKU-1270, 19, including the nine D-1 survivors) and `eku1272_mutants.py` (EKU-1272, 24 mutants of the R2-D/D-2/D-3 checks) are kept with the EKU-1272 evidence.

## 12. Remaining human decisions (none is requested by this revision)

0. **N-2:** accept that an unlinked, hashless or dropped-and-unlandable reservation stops T2 permanently (§7). No void or recovery authority is requested.

1. **Stage A:** approve key preparation and name the 1Password vault.
2. Validate and name the eligible free faucet sources per chain, and the human who uses their own faucet access where a source requires it. No operator or signer is assumed.
3. **Stage B:** approve the exact scope digest after binding, the CSO/CFO/QA re-review of this head, and a fresh lane snapshot.
4. Confirm SafeL2 1.4.1 as the T2 canceller singleton.
5. Accept the remaining testnet divergences:
   - a test-token-weighted Staker (production Staker class differs)
   - shortened timing (3600 / 86400 / 604800)
   - dummy targets
   - low-traffic lanes
   - no real out-of-gas reproduction (L-e)
