#!/usr/bin/env python3
"""EKU-1261 T2 guard (TESTNET ONLY): the only component that signs or sends a T2 transaction.

It binds every T2 signing step to the approved scope, the bound addresses and a durable spend ledger:

* scope (T2-3): the canonical scope digest = sha256 over the manifest, the binding addendum and every tooling file is
  recomputed from a clean git tree and compared with the committed approval record `binding/t2-approval.json`
  (stage `final-transactions`, unexpired). Environment variables never approve anything; identities, Safe salt,
  Governor felt and fee cap are exported FROM the bound addendum, and a conflicting pre-set value is refused.
* ledger (F1): an append-only, hash-chained, fsync'd JSONL ledger under an exclusive non-blocking lock. Before a
  transaction is signed, its maximum liability (gas limit x max fee per gas + value, or the Starknet max fee) is
  reserved and checked against cumulative per-chain, per-role, per-kind count, message and fee limits. Failed,
  reverted, replaced and manual attempts count. Unknown outcomes stay reserved at their maximum until reconciled from
  a receipt; a reservation that was never linked to signed bytes is never released (N-2). On-chain nonces of every
  role must equal the ledger's mined count, so a deleted ledger, a manual transaction or a lost receipt fails closed.
  The ledger directory comes only from the bound addendum (N-3).
* pre-sign (F1, CFO R1): the unsigned intent (chain, role, nonce, kind, attempt number, maximum liability) is
  reserved durably BEFORE any signer runs. Each planned EVM transaction is then signed with `cast mktx` (encrypted
  keystore, password in a memfd), decoded with `cast decode-transaction`, every signed field (signer, chain, nonce,
  to, value, input, gas, max fee, priority fee) is compared with the reserved intent, and the signed bytes are linked
  durably BEFORE `cast publish`. A reservation that was never linked (crash while signing) is never released.
* Starknet identity (CFO R2, R2-D): the bound account address must be the DEPLOY_ACCOUNT address derived (public
  data only) from the pinned OpenZeppelin class, the bound salt and constructor [public key]; the sncast account
  descriptor is generated from that bound identity, the keystore bytes must match the bound sha256, and the on-chain
  class and public key are checked, all before any password access. EVM keystores are bound by sha256 per signing
  role and frozen before the reservation (CSO D-2). sncast gets explicit resource bounds, tip 0 and --nonce; the
  transaction returned by the chain must match the reserved sender, nonce, payload, type and bounds before it is
  credited, and an actual fee above the reservation stops T2.
* stop conditions (T2-2): before every attempt, all logs of the T2 contracts must come from ledger transactions
  (executor Pinged/Queued must carry a payload hash this ledger dispatched), the proxy nonce must equal the ledger's
  L1 executions, the Safe signers must never have sent a transaction, and every T2 Governor/Staker/token event on
  Starknet must come from a ledger transaction. Any unknown proposal, vote, request, message or nonce stops T2.

No private key or password is printed, written or put in argv or the environment of a cast process.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable

# ------------------------------------------------------------------------------------------------ hard ceilings
# The committed limits file (t2-limits.json, part of the approved digest) may only LOWER these. Raising requires a code
# change, i.e. a new exact-SHA review and a new approval.
SEPOLIA, BNB_TESTNET, MONAD_TESTNET = 11155111, 97, 10143
EVM_CHAINS = (SEPOLIA, BNB_TESTNET, MONAD_TESTNET)
STARKNET_SEPOLIA = "SN_SEPOLIA"
GWEI = 10**9
ETHER = 10**18
HARD = {
    "chain_cap_wei": {SEPOLIA: 25 * ETHER // 100, BNB_TESTNET: 5 * ETHER // 100, MONAD_TESTNET: 2 * ETHER},
    "gas_price_ceiling_wei": {SEPOLIA: 20 * GWEI, BNB_TESTNET: 3 * GWEI, MONAD_TESTNET: 200 * GWEI},
    "role_cap_wei": {
        SEPOLIA: {"deployer": 6 * ETHER // 100, "bootstrap": ETHER // 100, "payer": 18 * ETHER // 100},
        BNB_TESTNET: {"deployer": 3 * ETHER // 100, "payer": 2 * ETHER // 100},
        MONAD_TESTNET: {"deployer": 14 * ETHER // 10, "payer": 6 * ETHER // 10},
    },
    "ccip_fee_max_wei": 2 * 10**15,
    "ccip_fee_total_wei": 18 * 10**15,
    "ccip_messages_max": 9,
    "starknet_cap_fri": 50 * ETHER,
    "starknet_fee_cap_fri": 48 * ETHER,
    "starknet_tx_max_fri": 10 * ETHER,
}
PRODUCTION_CHAINS = (1, 56, 143)
COMPANY_KEY = "0x00000c771f6176268d5a9846e0956c3ef58597a1"
L1_PROXY = "0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc"
PRODUCTION_L2_GOVERNOR = 0x053499F7AA2706395060FE72D00388803FB2DCC111429891AD7B2D9DCEA29ACD
# Anvil/Hardhat default mnemonic accounts 0-9: publicly known keys, never acceptable as T2 identities.
PUBLIC_DEV_ADDRESSES = {
    "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
    "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc", "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
    "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65", "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc",
    "0x976ea74026e726554db657fa54763abd0c3a0aa9", "0x14dc79964da2c08b23698b3d3cc7ca32193d9955",
    "0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f", "0xa0ee7a142d267c1f36714e4a8f75612f20a79720",
}

T2_DIR = Path(__file__).resolve().parent
BINDING_DIR = T2_DIR / "binding"
MANIFEST = BINDING_DIR / "t2-manifest.md"
BINDING = BINDING_DIR / "t2-binding.json"
APPROVAL = BINDING_DIR / "t2-approval.json"
LIMITS = T2_DIR / "t2-limits.json"
SCOPE_PATHS = ("l1_proxy/script", "l1_proxy/src", "l1_proxy/vendor", "l1_proxy/lib", "l1_proxy/foundry.toml",
               "src", "Scarb.toml", "Scarb.lock")
APPROVAL_REL = "l1_proxy/script/t2/binding/t2-approval.json"
MAX_APPROVAL_SECONDS = 14 * 86400
# Variables the guard derives from the bound addendum; a different pre-set value is a raised override and is refused.
BOUND_ENV = ("T2_DEPLOYER", "T2_BOOTSTRAP", "T2_PAYER", "T2_SAFE_OWNERS", "T2_SAFE_SALT", "T2_L2_GOVERNOR",
             "T2_STARKNET_ACCOUNT", "T2_SAFE_97", "T2_SAFE_10143", "T2_MAX_FEE_WEI", "T2_STAKE",
             "T2_BINDING_JSON", "T2_BINDING_SHA256", "T2_SCOPE_DIGEST", "T2_LEDGER_DIR", "T2_OP_VAULT")


class Refused(Exception):
    """A fail-closed refusal: nothing was signed or sent by the refusing call."""


def refuse(msg: str) -> None:
    raise Refused(msg)


def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(s: str) -> dt.datetime:
    t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if t.tzinfo is None:
        refuse(f"timestamp without timezone: {s}")
    return t


# ------------------------------------------------------------------------------------------------ scope (T2-3)
def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


def repo_root() -> Path:
    return Path(git(T2_DIR, "rev-parse", "--show-toplevel").strip())


def tooling_digest(root: Path) -> str:
    """sha256 over `<sha256(file)>  <path>` lines for every tracked file in scope (submodules: gitlink commit)."""
    lines = []
    for entry in git(root, "ls-files", "-s", "--", *SCOPE_PATHS).splitlines():
        meta, path = entry.split("\t", 1)
        mode, obj, _stage = meta.split()
        if path == APPROVAL_REL:
            continue
        if mode == "160000":
            lines.append(f"submodule:{obj}  {path}")
        else:
            lines.append(f"{sha256_hex((root / path).read_bytes())}  {path}")
    lines.sort(key=lambda l: l.split("  ", 1)[1])
    return sha256_hex(("\n".join(lines) + "\n").encode())


@dataclass
class Scope:
    manifest_sha256: str
    binding_sha256: str
    tooling_sha256: str
    digest: str
    binding: dict
    binding_text: str
    head: str


def compute_scope(root: Path | None = None, require_clean: bool = True) -> Scope:
    root = root or repo_root()
    if require_clean:
        dirty = git(root, "status", "--porcelain", "--untracked-files=all", "--", *SCOPE_PATHS).strip()
        if dirty:
            refuse("scope files differ from the committed tree (any changed byte refuses):\n" + dirty)
    for p in (MANIFEST, BINDING, LIMITS):
        if not p.is_file():
            refuse(f"missing scope file {p}")
    btext = BINDING.read_text()
    m, b, t = sha256_hex(MANIFEST.read_bytes()), sha256_hex(btext.encode()), tooling_digest(root)
    digest = sha256_hex(f"ekubo-t2-scope-v1\nmanifest {m}\nbinding {b}\ntooling {t}\n".encode())
    return Scope(m, b, t, digest, json.loads(btext), btext, git(root, "rev-parse", "HEAD").strip())


def load_limits() -> dict:
    lim = json.loads(LIMITS.read_text())
    if lim.get("schema") != "ekubo-t2-limits-v1":
        refuse("t2-limits.json: schema")
    for cid in EVM_CHAINS:
        c = lim["evm"][str(cid)]
        if int(c["chain_cap_wei"]) > HARD["chain_cap_wei"][cid]:
            refuse(f"limits raise the chain cap on {cid}")
        if int(c["gas_price_ceiling_wei"]) > HARD["gas_price_ceiling_wei"][cid]:
            refuse(f"limits raise the gas-price ceiling on {cid}")
        roles = c["role_cap_wei"]
        if set(roles) != set(HARD["role_cap_wei"][cid]):
            refuse(f"limits: role set on {cid}")
        for r, v in roles.items():
            if int(v) > HARD["role_cap_wei"][cid][r]:
                refuse(f"limits raise the {r} cap on {cid}")
        if sum(int(v) for v in roles.values()) > int(c["chain_cap_wei"]):
            refuse(f"limits: role caps exceed the chain cap on {cid}")
        for k, kind in c["kinds"].items():
            if kind["role"] not in roles:
                refuse(f"limits: kind {k} has unknown role")
            if int(kind.get("value_max_wei", 0)) > (HARD["ccip_fee_max_wei"] if k == "dispatch" else 0):
                refuse(f"limits: kind {k} may carry value")
    if int(lim["ccip"]["fee_max_wei"]) > HARD["ccip_fee_max_wei"]:
        refuse("limits raise the per-message CCIP fee")
    if int(lim["ccip"]["fee_total_wei"]) > HARD["ccip_fee_total_wei"]:
        refuse("limits raise the total CCIP fee")
    if int(lim["ccip"]["messages_max"]) > HARD["ccip_messages_max"]:
        refuse("limits raise the CCIP message count")
    sn = lim["starknet"]
    if int(sn["fee_cap_fri"]) > HARD["starknet_fee_cap_fri"] or int(sn["balance_cap_fri"]) > HARD["starknet_cap_fri"]:
        refuse("limits raise the Starknet caps")
    if int(sn["fee_cap_fri"]) + int(sn["non_fee_reserve_fri"]) > int(sn["balance_cap_fri"]):
        refuse("limits: Starknet fee cap + non-fee reserve exceed the balance cap")
    for k, kind in sn["kinds"].items():
        if int(kind["max_fee_fri"]) > HARD["starknet_tx_max_fri"]:
            refuse(f"limits raise the Starknet per-tx max fee for {k}")
    return lim


def is_public_or_production(a: str) -> bool:
    a = a.lower()
    return a in PUBLIC_DEV_ADDRESSES or a in (COMPANY_KEY, L1_PROXY) or int(a, 16) >> 144 in (0x1232, 0x1199) \
        or int(a, 16) == 0


def check_binding(b: dict, lim: dict) -> None:
    if b.get("schema") != "ekubo-t2-binding-v1":
        refuse("binding: schema")
    if b.get("status") != "BOUND":
        refuse("binding: status is not BOUND (addresses are bound only after key generation)")
    check_sn_account_binding(b)  # R2-D first: derived Starknet address == every bound Starknet address field
    r = b["roles"]
    evm = [r["deployer"], r["bootstrap"], r["payer"], *r["safe_owners"]]
    if len(r["safe_owners"]) != 3:
        refuse("binding: exactly 3 Safe owners")
    if len({a.lower() for a in evm}) != len(evm):
        refuse("binding: EVM roles must be pairwise distinct (deployer, bootstrap, payer, 3 Safe owners)")
    for a in evm:
        if is_public_or_production(a):
            refuse(f"binding: {a} is a placeholder, public dev key, company key or production address")
    g = int(b["starknet"]["governor"], 16)
    if g == 0 or g >= 1 << 251 or g == PRODUCTION_L2_GOVERNOR:
        refuse("binding: T2 Governor felt")
    if int(b["limits"]["ccip_fee_max_wei"]) != int(lim["ccip"]["fee_max_wei"]):
        refuse("binding: ccip_fee_max_wei != t2-limits.json")
    if int(b["starknet"]["stake_amount"]) != int(lim["starknet"]["stake_amount"]):
        refuse("binding: stake_amount != t2-limits.json")
    # F4: only bound roles on bound chains may receive faucet funds, within the per-role caps; Safe owners nothing.
    seen = set()
    for f in b["funding_recipients"]:
        chain, role, addr, mx = f["chain"], f["role"], f["address"].lower(), int(f["max"])
        key = (chain, role)
        if key in seen:
            refuse(f"binding: duplicate funding recipient {key}")
        seen.add(key)
        if role.startswith("safe"):
            refuse("binding: Safe signers are never funded")
        if chain == f"starknet:{STARKNET_SEPOLIA}":
            if role != "starknet" or addr != b["roles"]["starknet_account"].lower():
                refuse("binding: Starknet funding recipient")
            if mx > int(lim["starknet"]["balance_cap_fri"]):
                refuse("binding: Starknet funding above cap")
            continue
        cid = int(chain.split(":")[1]) if chain.startswith("eip155:") else -1
        if cid not in EVM_CHAINS or role not in lim["evm"][str(cid)]["role_cap_wei"]:
            refuse(f"binding: funding recipient {chain}/{role} is not a funded role")
        if addr != r[role].lower():
            refuse(f"binding: funding recipient {chain}/{role} address != bound role")
        if mx > int(lim["evm"][str(cid)]["role_cap_wei"][role]):
            refuse(f"binding: funding for {chain}/{role} above the role cap")
    expected = {(f"eip155:{c}", rr) for c in EVM_CHAINS for rr in lim["evm"][str(c)]["role_cap_wei"]}
    expected.add((f"starknet:{STARKNET_SEPOLIA}", "starknet"))
    if seen != expected:
        refuse("binding: funding recipients must be exactly the funded roles per chain")
    if not isinstance(b.get("op_vault"), str) or not b["op_vault"].strip():
        refuse("binding: op_vault (the named 1Password vault) is required")
    check_ledger_dir(b.get("ledger_dir"))
    check_evm_keystores(b)
    check_faucet_sources(b)


def check_ledger_dir(d: Any) -> None:
    """N-3: one absolute, normalized ledger directory is bound, so two runners cannot select separate ledgers/locks."""
    if not isinstance(d, str) or not d.startswith("/") or os.path.normpath(d) != d:
        refuse("binding: ledger_dir must be one absolute, normalized path (no ~, no .., no trailing /)")


def _felt(v: Any, what: str) -> int:
    try:
        x = int(str(v), 16)
    except ValueError:
        x = -1
    if not str(v).startswith("0x") or not 0 < x < 1 << 251:
        refuse(f"binding: {what} is not a non-zero felt")
    return x


# ---- Starknet DEPLOY_ACCOUNT address derivation (CFO R2-D): public data only, no RPC, no key, no sncast.
# Stark curve y^2 = x^3 + x + beta over p, and the Pedersen constant points of starkware `pedersen_params.json`
# (CONSTANT_POINTS[0] shift point, [2], [250], [254], [502]). Each point is checked on the curve at import.
SN_P = 2**251 + 17 * 2**192 + 1
SN_BETA = 0x6f21413efbe40de150e596d72f7a8c5609ad26c15c915c1f4cdfcb99cee9e89
SN_PEDERSEN_POINTS = (
    (0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804,
     0x3ca0cfe4b3bc6ddf346d49d06ea0ed34e621062c0e056c1d0405d266e10268a),
    (0x234287dcbaffe7f969c748655fca9e58fa8120b6d56eb0c1080d17957ebe47b,
     0x3b056f100f96fb21e889527d41f4e39940135dd7a6c94cc6ed0268ee89e5615),
    (0x4fa56f376c83db33f9dab2656558f3399099ec1de5e3018b7a6932dba8aa378,
     0x3fa0984c931c9e38113e0c0e47e4401562761f92a7a23b45168f4e80ff5b54d),
    (0x4ba4cc166be8dec764910f75b45f74b40c690c74709e90f3aa372f0bd2d6997,
     0x40301cf5c1751f4b971e46c4ede85fcac5c59a5ce5ae7c48151f27b24b219c),
    (0x54302dcb0e6cc1c6e44cca8f61a63bb2ca65048d53fb325d36ff12c49a58202,
     0x1b77b3e37d13504b348046268d8ae25ce98ad783c25561a879dcc77e99c2426),
)
assert all((y * y - x**3 - x - SN_BETA) % SN_P == 0 for x, y in SN_PEDERSEN_POINTS)
SN_CONTRACT_ADDRESS_PREFIX = int.from_bytes(b"STARKNET_CONTRACT_ADDRESS", "big")
SN_ADDRESS_BOUND = 2**251 - 256
# The ONLY supported T2 account: the OpenZeppelin account class that installed sncast 0.62.1 `account create`
# (type open-zeppelin) uses, constructor(public_key) => calldata [public_key], deployed by DEPLOY_ACCOUNT (deployer
# address 0, salt not modified). Any other class, constructor or deployer is refused, not guessed.
SN_OZ_ACCOUNT_CLASS = "0x05b4b537eaa2399e3aa99c4e2e0208ebd6c71bc1467938cd52c798c601e43564"


def _ec_add(a: tuple[int, int] | None, b: tuple[int, int] | None) -> tuple[int, int] | None:
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0]:
        if (a[1] + b[1]) % SN_P == 0:
            return None
        lam = (3 * a[0] * a[0] + 1) * pow(2 * a[1], -1, SN_P) % SN_P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, SN_P) % SN_P
    x = (lam * lam - a[0] - b[0]) % SN_P
    return x, (lam * (a[0] - x) - a[1]) % SN_P


def _ec_mul(k: int, pt: tuple[int, int]) -> tuple[int, int] | None:
    acc = None
    cur: tuple[int, int] | None = pt
    while k:
        if k & 1:
            acc = _ec_add(acc, cur)
        cur = _ec_add(cur, cur)
        k >>= 1
    return acc


def sn_pedersen(a: int, b: int) -> int:
    """Starknet Pedersen hash: x of shift + a_low*P0 + a_high*P1 + b_low*P2 + b_high*P3 (248-bit low parts)."""
    if not (0 <= a < SN_P and 0 <= b < SN_P):
        refuse("pedersen input is not a field element")
    shift, p0, p1, p2, p3 = SN_PEDERSEN_POINTS
    r: tuple[int, int] | None = shift
    for v, lo, hi in ((a, p0, p1), (b, p2, p3)):
        r = _ec_add(r, _ec_mul(v & ((1 << 248) - 1), lo))
        r = _ec_add(r, _ec_mul(v >> 248, hi))
    assert r is not None
    return r[0]


def sn_hash_on_elements(xs: list[int]) -> int:
    h = 0
    for x in xs:
        h = sn_pedersen(h, x)
    return sn_pedersen(h, len(xs))


def sn_contract_address(class_hash: int, salt: int, ctor: list[int], deployer: int = 0) -> int:
    """Starknet contract address: pedersen-chain(prefix, deployer, salt, class hash, H(ctor)) mod 2**251 - 256."""
    return sn_hash_on_elements([SN_CONTRACT_ADDRESS_PREFIX, deployer, salt, class_hash,
                                sn_hash_on_elements(ctor)]) % SN_ADDRESS_BOUND


def sn_account_address(s: dict) -> int:
    """The DEPLOY_ACCOUNT address of the bound (pinned) OpenZeppelin account identity."""
    pub = _felt(s.get("account_public_key"), "starknet account public key")
    cls = _felt(s.get("account_class_hash"), "starknet account class hash")
    salt = _felt(s.get("account_salt"), "starknet account salt")
    if cls != int(SN_OZ_ACCOUNT_CLASS, 16):
        refuse(f"binding: starknet account class {s.get('account_class_hash')} is not the supported OpenZeppelin "
               f"account class {SN_OZ_ACCOUNT_CLASS} (no other account class or constructor is supported)")
    return sn_contract_address(cls, salt, [pub], 0)


def check_sn_account_binding(b: dict) -> None:
    """CFO R2/R2-D: the Starknet account identity is public metadata frozen in the addendum (no secret material). The
    account address is DERIVED from the pinned class, salt and constructor calldata [public key] with deployer 0
    (DEPLOY_ACCOUNT) and must equal roles.starknet_account, starknet.account and every Starknet funding recipient.
    Runs in check_binding (bind, every authorized command) and again before any password or signer is constructed."""
    s, roles = b.get("starknet") or {}, b.get("roles") or {}
    if s.get("account_type") != "open_zeppelin":
        refuse("binding: starknet account_type must be open_zeppelin")
    derived = sn_account_address(s)
    rcp = [f for f in b.get("funding_recipients") or [] if f.get("chain") == f"starknet:{STARKNET_SEPOLIA}"]
    if not rcp:
        refuse("binding: no Starknet funding recipient")
    for what, v in (("roles.starknet_account", roles.get("starknet_account")), ("starknet.account", s.get("account")),
                    *((f"Starknet funding recipient {f.get('role')}", f.get("address")) for f in rcp)):
        if _felt(v, what) != derived:
            refuse(f"binding: {what} {v} != {hex(derived)}, the DEPLOY_ACCOUNT address derived from the bound class, "
                   "salt and public key: refused before any password or signer")
    ks = s.get("keystore_sha256") or ""
    if not _is_sha256(ks):
        refuse("binding: starknet keystore_sha256 (sha256 of the encrypted keystore file) is required")


def _is_sha256(v: Any) -> bool:
    return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)


EVM_SIGNING_ROLES = ("deployer", "bootstrap", "payer")


def check_evm_keystores(b: dict) -> None:
    """CSO D-2: the sha256 of each EVM signing role's encrypted keystore file is bound, like the Starknet one. Safe
    owners never sign through the guard (offline safeTxHash signatures only), so they have no bound keystore."""
    ks = b.get("evm_keystore_sha256")
    if not isinstance(ks, dict) or set(ks) != set(EVM_SIGNING_ROLES) or not all(_is_sha256(ks[r]) for r in ks):
        refuse("binding: evm_keystore_sha256 needs the sha256 of the encrypted keystore of exactly deployer, "
               "bootstrap and payer")
    vals = [*ks.values(), (b.get("starknet") or {}).get("keystore_sha256")]
    if len(set(vals)) != len(vals):
        refuse("binding: keystore digests must be pairwise distinct (one keystore per role)")


FAUCET_FIELDS = ("chain", "source", "url", "eligibility", "eligibility_checked_at", "drip_max", "login", "region",
                 "operator")


def check_faucet_sources(b: dict) -> None:
    """CFO F4 / N-7: no final binding without filled, eligible, free faucet sources for every funded chain."""
    src = b.get("faucet_sources") or []
    if not src:
        refuse("binding: faucet_sources is empty: validated free faucet sources are required before stage B")
    chains = {f["chain"] for f in b["funding_recipients"]}
    per: dict[str, int] = {}
    names = set()
    for f in src:
        for k in FAUCET_FIELDS:
            if not str(f.get(k) or "").strip():
                refuse(f"binding: faucet source {f.get('source')!r} lacks {k}")
        if f["chain"] not in chains:
            refuse(f"binding: faucet source {f['source']} is for an unfunded chain {f['chain']}")
        if f.get("paid") is not False or f.get("mainnet_prerequisite") is not False:
            refuse(f"binding: faucet source {f['source']} must be free and need no mainnet balance (paid=false, "
                   "mainnet_prerequisite=false)")
        if not isinstance(f.get("automated_allowed"), bool):
            refuse(f"binding: faucet source {f['source']}: automated_allowed must be true or false")
        if f["operator"].strip().lower() == "agent" and not f["automated_allowed"]:
            refuse(f"binding: faucet source {f['source']} needs a named human operator (automated requests not allowed)")
        if int(f["drip_max"]) <= 0:
            refuse(f"binding: faucet source {f['source']}: drip_max")
        parse_ts(f["eligibility_checked_at"])
        if (f["chain"], f["source"]) in names:
            refuse(f"binding: duplicate faucet source {f['source']} on {f['chain']}")
        names.add((f["chain"], f["source"]))
        per[f["chain"]] = per.get(f["chain"], 0) + 1
    for c in chains:
        if not 1 <= per.get(c, 0) <= 2:
            refuse(f"binding: {c} needs one or two named free faucet sources (has {per.get(c, 0)})")


def check_approval(scope: Scope, at: dt.datetime | None = None) -> dict:
    at = at or now_utc()
    if not APPROVAL.is_file():
        refuse("no approval record (binding/t2-approval.json): the final T2 authorization has not been saved")
    a = json.loads(APPROVAL.read_text())
    if a.get("schema") != "ekubo-t2-approval-v1":
        refuse("approval: schema")
    if a.get("stage") != "final-transactions":
        refuse(f"approval stage {a.get('stage')!r} does not authorize transactions (key preparation is a separate, "
               "earlier gate; computing addresses never approves execution)")
    for k in ("manifest_sha256", "binding_sha256", "tooling_sha256", "scope_digest"):
        want = {"manifest_sha256": scope.manifest_sha256, "binding_sha256": scope.binding_sha256,
                "tooling_sha256": scope.tooling_sha256, "scope_digest": scope.digest}[k]
        if a.get(k) != want:
            refuse(f"approval {k} {a.get(k)} != recomputed {want}")
    t0, t1 = parse_ts(a["approved_at"]), parse_ts(a["expires_at"])
    if (t1 - t0).total_seconds() > MAX_APPROVAL_SECONDS or t1 <= t0:
        refuse("approval window longer than 14 days")
    if not (t0 <= at < t1):
        refuse(f"approval not valid now ({a['approved_at']} .. {a['expires_at']})")
    if not a.get("approved_by") or not a.get("approval_ref"):
        refuse("approval: approved_by and approval_ref are required")
    return a


def bound_env(scope: Scope, lim: dict) -> dict[str, str]:
    b, r = scope.binding, scope.binding["roles"]
    return {
        "T2_DEPLOYER": r["deployer"], "T2_BOOTSTRAP": r["bootstrap"], "T2_PAYER": r["payer"],
        "T2_SAFE_OWNERS": ",".join(r["safe_owners"]), "T2_SAFE_SALT": str(int(b["safe_salt"])),
        "T2_L2_GOVERNOR": b["starknet"]["governor"], "T2_STARKNET_ACCOUNT": r["starknet_account"],
        "T2_SAFE_97": b["predicted"]["safe_97"], "T2_SAFE_10143": b["predicted"]["safe_10143"],
        "T2_MAX_FEE_WEI": str(int(lim["ccip"]["fee_max_wei"])), "T2_STAKE": str(int(lim["starknet"]["stake_amount"])),
        # The exported text drops the file's trailing newline (shell and forge env handling would); its own sha256 is
        # what T2Route checks. The scope digest covers the exact file bytes.
        "T2_BINDING_JSON": scope.binding_text.rstrip("\n"),
        "T2_BINDING_SHA256": "0x" + sha256_hex(scope.binding_text.rstrip("\n").encode()),
        "T2_SCOPE_DIGEST": scope.digest,
        "T2_LEDGER_DIR": b["ledger_dir"], "T2_OP_VAULT": b["op_vault"],
    }


def refuse_overrides(env: dict[str, str], current: dict[str, str] | None = None) -> None:
    current = os.environ if current is None else current
    for k, v in env.items():
        if k in current and current[k] != v:
            refuse(f"{k} is pre-set to a value that differs from the bound addendum: refusing (no overrides)")


def authorize() -> tuple[Scope, dict, dict, dict[str, str]]:
    scope = compute_scope()
    lim = load_limits()
    check_binding(scope.binding, lim)
    appr = check_approval(scope)
    env = bound_env(scope, lim)
    refuse_overrides(env)
    return scope, lim, appr, env


# ------------------------------------------------------------------------------------------------ RPC
class RpcError(RuntimeError):
    """A JSON-RPC error object; callers match the exact numeric `code`, never a substring of the text (N-6)."""

    def __init__(self, method: str, err: Any):
        self.code = err.get("code") if isinstance(err, dict) else None
        super().__init__(f"{method}: {err}")


class Rpc:
    def __init__(self, url: str):
        self.url = url

    def call(self, method: str, params: list) -> Any:
        req = urllib.request.Request(self.url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                                           "params": params}).encode(),
                                     {"content-type": "application/json", "user-agent": "ekubo-t2-guard"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            out = json.load(resp)
        if "error" in out:
            raise RpcError(method, out["error"])
        return out["result"]


def require_chain_ids(chains: dict[int, Any]) -> None:
    """N-4: every EVM RPC the guard reads, watches or reconciles must report its expected chain id."""
    for cid, chain in chains.items():
        got = chain.chain_id()
        if got != cid:
            refuse(f"RPC for chain {cid} reports chain id {got}: stop")


def rpc_url(cid: int) -> str:
    var = {SEPOLIA: "SEPOLIA_RPC_URL", BNB_TESTNET: "BNB_TESTNET_RPC_URL", MONAD_TESTNET: "MONAD_TESTNET_RPC_URL"}[cid]
    url = os.environ.get(var)
    if not url:
        refuse(f"{var} unset")
    return url


class EvmChain:
    """Live chain access; tests substitute a fake with the same methods."""

    def __init__(self, cid: int, url: str):
        self.cid, self.rpc = cid, Rpc(url)

    def chain_id(self) -> int:
        return int(self.rpc.call("eth_chainId", []), 16)

    def nonce(self, a: str, tag: str = "latest") -> int:
        return int(self.rpc.call("eth_getTransactionCount", [a, tag]), 16)

    def base_fee(self) -> int:
        blk = self.rpc.call("eth_getBlockByNumber", ["latest", False])
        bf = blk.get("baseFeePerGas")
        return int(bf, 16) if bf else int(self.rpc.call("eth_gasPrice", []), 16)

    def priority_fee(self) -> int:
        try:
            return int(self.rpc.call("eth_maxPriorityFeePerGas", []), 16)
        except Exception:
            return 0

    def receipt(self, h: str) -> dict | None:
        return self.rpc.call("eth_getTransactionReceipt", [h])

    def publish(self, raw: str) -> str:
        return self.rpc.call("eth_sendRawTransaction", [raw])

    def block_number(self) -> int:
        return int(self.rpc.call("eth_blockNumber", []), 16)

    def logs(self, address: str, frm: int, to: int) -> list:
        return self.rpc.call("eth_getLogs", [{"address": address, "fromBlock": hex(frm), "toBlock": hex(to)}])

    def call(self, to: str, data: str) -> str:
        return self.rpc.call("eth_call", [{"to": to, "data": data}, "latest"])


# ------------------------------------------------------------------------------------------------ ledger (F1)
GENESIS = "0" * 64


class Ledger:
    """Append-only JSONL, one record per line, each carrying the sha256 of the previous line. Exclusive flock."""

    def __init__(self, path: Path):
        self.path = path
        self.lock_path = path.with_suffix(".lock")
        self.lock_fd: int | None = None
        self.records: list[dict] = []

    def __enter__(self) -> "Ledger":
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock_fd)
            self.lock_fd = None
            refuse(f"ledger {self.path} is locked by another T2 runner: concurrent attempts are refused")
        try:
            self._load()
        except BaseException:
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc: Any) -> None:
        if self.lock_fd is not None:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            self.lock_fd = None

    def _load(self) -> None:
        self.records = []
        if not self.path.exists():
            return
        prev = GENESIS
        data = self.path.read_bytes()
        if data and not data.endswith(b"\n"):
            refuse("ledger: torn final record (crash during write): reconcile manually, never truncate")
        for i, line in enumerate(data.splitlines()):
            rec = json.loads(line)
            if rec.get("prev") != prev or rec.get("seq") != i:
                refuse(f"ledger: hash chain or sequence broken at line {i}: tampered or corrupted")
            prev = sha256_hex(line)
            self.records.append(rec)

    def append(self, rec: dict) -> dict:
        assert self.lock_fd is not None, "ledger not locked"
        prev = sha256_hex(json.dumps(self.records[-1], sort_keys=True, separators=(",", ":")).encode()) \
            if self.records else GENESIS
        rec = {**rec, "seq": len(self.records), "prev": prev, "ts": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")}
        line = json.dumps(rec, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
        dfd = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
        self.records.append(rec)
        return rec

    # ---- derived state
    def attempts(self, chain: Any = None) -> list[dict]:
        return [r for r in self.records if r["type"] == "reserve" and (chain is None or r["chain"] == chain)]

    def outcome(self, seq: int) -> dict | None:
        for r in self.records:
            if r["type"] in ("outcome", "void") and r["ref"] == seq:
                return r
        return None

    def open_reserves(self, chain: Any = None) -> list[dict]:
        return [a for a in self.attempts(chain) if self.outcome(a["seq"]) is None]

    def exposure(self, chain: Any, role: str | None = None) -> int:
        """Spent (actual, from receipts) + open reservations (at their maximum), in native units."""
        total = 0
        for a in self.attempts(chain):
            if role is not None and a["role"] != role:
                continue
            o = self.outcome(a["seq"])
            if o is None:
                total += int(a["max_cost"])
            elif o["type"] == "outcome":
                total += int(o["cost"])
        return total

    def kind_count(self, chain: Any, kind: str) -> int:
        return sum(1 for a in self.attempts(chain) if a["kind"] == kind)

    def ccip(self) -> tuple[int, int]:
        """(successful messages, message fees spent or reserved)."""
        msgs, fees = 0, 0
        for a in self.attempts(SEPOLIA):
            if a["kind"] != "dispatch":
                continue
            o = self.outcome(a["seq"])
            if o is None:
                msgs, fees = msgs + 1, fees + int(a["value"])
            elif o["type"] == "outcome" and o["status"] == 1:
                msgs, fees = msgs + max(1, len(o.get("dispatched", []))), fees + int(a["value"])
        return msgs, fees

    def link(self, a: dict) -> dict | None:
        """The record that links a reservation (written BEFORE any signer runs) to its signed bytes: `signed` (EVM,
        hash and raw bytes, written after verification and before publishing) or `sn-sent` (Starknet, hash returned
        by sncast). A reservation without a link has an unknown outcome that cannot be reconstructed (N-2)."""
        for r in self.records:
            if r["type"] in ("signed", "sn-sent") and r["ref"] == a["seq"]:
                return r
        return None

    def tx_hash(self, a: dict) -> str:
        if a.get("hash"):  # records written before EKU-1268 carried the hash in the reservation itself
            return a["hash"].lower()
        lk = self.link(a)
        return lk["hash"].lower() if lk else ""

    def raw(self, a: dict) -> str:
        if a.get("raw"):
            return a["raw"]
        lk = self.link(a)
        return lk.get("raw", "") if lk else ""

    def overruns(self) -> list[dict]:
        """Reservations whose recorded actual cost exceeded the reserved maximum (N-5): a permanent stop."""
        return [a for a in self.attempts() if (o := self.outcome(a["seq"])) is not None and o["type"] == "outcome"
                and int(o["cost"]) > int(a["max_cost"])]

    def incidents(self) -> list[dict]:
        return [r for r in self.records if r["type"] == "incident"]

    def mined_hashes(self, chain: Any) -> set[str]:
        out = set()
        for a in self.attempts(chain):
            o = self.outcome(a["seq"])
            if o and o["type"] == "outcome":
                out.add(self.tx_hash(a))
        return out

    def dispatched_payloads(self) -> set[str]:
        out = set()
        for r in self.records:
            if r["type"] == "outcome":
                out.update(x.lower() for x in r.get("dispatched", []))
        return out

    def mined_count(self, chain: Any, address: str) -> int:
        return sum(1 for a in self.attempts(chain) if a["from"].lower() == address.lower()
                   and (o := self.outcome(a["seq"])) is not None and o["type"] == "outcome")


def ledger_path(binding: dict) -> Path:
    """N-3: the directory comes only from the bound addendum (`ledger_dir`); `T2_LEDGER_DIR` is a BOUND_ENV value
    and a different pre-set value is refused, so separate ledgers or locks cannot be selected."""
    check_ledger_dir(binding.get("ledger_dir"))
    ident = sha256_hex(json.dumps(binding["roles"], sort_keys=True).encode())[:16]
    return Path(binding["ledger_dir"]) / f"ledger-{ident}.jsonl"


def require_no_stop(led: Ledger) -> None:
    if led.overruns():
        refuse(f"recorded actual cost above the reserved maximum (seq {led.overruns()[0]['seq']}): stop (N-5)")
    if led.incidents():
        refuse(f"ledger incident (seq {led.incidents()[0]['seq']}): {led.incidents()[0]['reason']}: stop")


# ------------------------------------------------------------------------------------------------ EVM reconciliation
def _topic(sig: str) -> str:
    return subprocess.run(["cast", "keccak", sig], check=True, capture_output=True, text=True).stdout.strip().lower()


def receipt_cost(cid: int, a: dict, rc: dict) -> int:
    gas_used = int(rc["gasUsed"], 16)
    eff = rc.get("effectiveGasPrice")
    price = int(eff, 16) if isinstance(eff, str) else int(a["max_fee"])
    if cid == MONAD_TESTNET:
        gas_used = max(gas_used, int(a["gas"]))  # Monad charges the gas limit
    value = int(a["value"]) if int(rc["status"], 16) == 1 else 0
    return gas_used * price + value


def record_receipt(led: Ledger, chain: EvmChain, a: dict, rc: dict, dispatched_topic: str) -> dict:
    status = int(rc["status"], 16)
    h = led.tx_hash(a)
    if not h or rc["from"].lower() != a["from"].lower() or rc["transactionHash"].lower() != h:
        refuse(f"receipt for {h or '<unlinked>'} does not match the reserved signer or hash")
    dispatched = []
    if a["kind"] == "dispatch" and status == 1:
        for lg in rc["logs"]:
            if lg["topics"] and lg["topics"][0].lower() == dispatched_topic:
                dispatched.append(lg["topics"][1])
    return led.append({"type": "outcome", "ref": a["seq"], "chain": a["chain"], "status": status,
                       "gas_used": int(rc["gasUsed"], 16), "block": int(rc["blockNumber"], 16),
                       "cost": str(receipt_cost(chain.cid, a, rc)), "dispatched": dispatched,
                       "contract": rc.get("contractAddress")})


def reconcile_evm(led: Ledger, chains: dict[int, EvmChain], roles: dict[str, str], republish: bool,
                  dispatched_topic: str, out: Callable[[str], None] = print) -> None:
    require_chain_ids(chains)
    for cid, chain in chains.items():
        for a in led.open_reserves(cid):
            h = led.tx_hash(a)
            if not h:
                # N-2: the guard stopped after the durable reservation but before the verified signed bytes were
                # linked (during or right after signing). Whether a signature exists, or was ever published, cannot
                # be reconstructed, and an absent transaction is not proof. The slot is never released: T2 stops
                # permanently; resuming needs a code change and a new approval.
                refuse(f"chain {cid}: reservation seq {a['seq']} ({a['kind']}, {a['role']} nonce {a['nonce']}, max "
                       f"{a['max_cost']}) has no linked signed transaction (stopped during or right after signing): "
                       "unresolved, never released: permanent stop (N-2)")
            rc = chain.receipt(h)
            if rc is None and republish:
                try:
                    chain.publish(led.raw(a))  # identical signed bytes: same hash, no new reservation or liability
                    out(f"republished reserved tx {h} (seq {a['seq']})")
                except Exception as e:  # noqa: BLE001
                    out(f"republish of {h} failed: {e}")
                rc = wait_receipt(chain, h, 180)
            if rc is not None:
                record_receipt(led, chain, a, rc, dispatched_topic)
                continue
            if chain.nonce(a["from"]) > int(a["nonce"]):
                twin = [b for b in led.attempts(cid) if b["from"].lower() == a["from"].lower()
                        and b["nonce"] == a["nonce"] and b["seq"] != a["seq"] and led.tx_hash(b)
                        and chain.receipt(led.tx_hash(b))]
                if twin:
                    led.append({"type": "void", "ref": a["seq"], "chain": cid,
                                "reason": f"nonce mined by {led.tx_hash(twin[0])}"})
                    continue
                refuse(f"chain {cid}: nonce {a['nonce']} of {a['from']} consumed by a transaction NOT in the ledger")
        for role, addr in roles.items():
            n = chain.nonce(addr)
            mined = led.mined_count(cid, addr)
            if n != mined:
                refuse(f"chain {cid}: on-chain nonce of {role} {addr} is {n} but the ledger has {mined} mined "
                       "transactions (deleted ledger, manual transaction or lost receipt): stop")


def wait_receipt(chain: EvmChain, h: str, seconds: int) -> dict | None:
    end = time.time() + seconds
    while True:
        rc = chain.receipt(h)
        if rc is not None or time.time() >= end:
            return rc
        time.sleep(2)


# ------------------------------------------------------------------------------------------------ EVM pre-sign checks
@dataclass
class PlannedTx:
    frm: str
    to: str | None
    value: int
    data: str
    nonce: int
    gas: int


def load_plan(path: Path, cid: int) -> list[PlannedTx]:
    j = json.loads(path.read_text())
    if int(j.get("chain", cid)) != cid:
        refuse(f"plan {path} is for chain {j.get('chain')}, not {cid}")
    out = []
    for t in j["transactions"]:
        tx = t["transaction"]
        to = tx.get("to")
        if t.get("transactionType") == "CREATE":
            to = None
        elif t.get("transactionType") != "CALL":
            refuse(f"plan: unsupported transaction type {t.get('transactionType')}")
        if int(tx.get("chainId", hex(cid)), 16) != cid:
            refuse("plan: chain id")
        out.append(PlannedTx(tx["from"].lower(), to.lower() if to else None, int(tx.get("value") or "0x0", 16),
                             (tx.get("input") or tx.get("data") or "0x").lower(), int(tx["nonce"], 16),
                             int(tx["gas"], 16)))
    if not out:
        refuse("plan has no transactions")
    return out


def classify(step: str, tx: PlannedTx, binding: dict, cid: int) -> str:
    """Map each planned transaction to exactly one ledger kind; anything unexpected is refused."""
    p, sel = binding["predicted"], tx.data[:10]
    n_targets = len(p["targets_97"]) if cid == BNB_TESTNET else len(p["targets_10143"])
    targets = {a.lower() for a in p["targets_97"] + p["targets_10143"]}
    kinds = {
        "proxy": lambda: "deploy-proxy" if tx.to is None else None,
        "sender": lambda: "deploy-sender" if tx.to is None else None,
        "dest": lambda: ("deploy-target" if tx.to is None and tx.nonce < n_targets else
                         "deploy-executor" if tx.to is None and tx.nonce == n_targets + 1 else
                         "safe-create" if tx.to == SAFE_FACTORY and sel == SEL["createProxyWithNonce"]
                         and tx.nonce == n_targets else None),
        "ping-request": lambda: "ping-request" if tx.to == p["sender"].lower() and sel == SEL["request"] else None,
        "handoff": lambda: "handoff" if tx.to == p["sender"].lower() and sel == SEL["handoff"] else None,
        "dispatch": lambda: "dispatch" if tx.to == p["sender"].lower() and sel == SEL["dispatch"] else None,
        "l1exec": lambda: "l1-execute" if tx.to == p["proxy"].lower() and sel == SEL["proxyExecute"] else None,
        "execute": lambda: "execute" if tx.to in (p["executor_97"].lower(), p["executor_10143"].lower())
        and sel == SEL["execute"] else None,
        "cancel": lambda: "safe-cancel" if tx.to in (p["safe_97"].lower(), p["safe_10143"].lower())
        and sel == SEL["execTransaction"] else None,
        "transfer": lambda: "transfer" if tx.to in targets and sel == SEL["transferOwnership"] else None,
        "manualexec": lambda: "manual-exec" if tx.to in OFFRAMPS_V2 and sel == SEL["offRampExecute"] else None,
    }
    if step not in kinds:
        refuse(f"unknown signing step {step}")
    k = kinds[step]()
    if k is None:
        refuse(f"step {step}: planned transaction to {tx.to} selector {sel} is not an allowed {step} transaction")
    return k


SAFE_FACTORY = "0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67"
OFFRAMPS_V2 = {"0x32d4dd31a03e82fe7b1b8c9e5e6fa028b2fca770", "0x8c7676a0e7289fe1ecb09d77a755e52afd5ec471"}
SEL = {
    "createProxyWithNonce": "0x1688f0b9", "request": "", "handoff": "", "dispatch": "", "proxyExecute": "",
    "execute": "", "execTransaction": "0x6a761202", "transferOwnership": "0xf2fde38b", "offRampExecute": "",
}


def _init_selectors() -> None:
    sigs = {
        "request": "request(uint64,uint32,uint64,(address,bytes)[])", "handoff": "handoff()",
        "dispatch": "dispatch(bytes)", "proxyExecute": "execute(address,uint256,uint64,bytes)",
        "execute": "execute(bytes)",
        # OffRamp 2.0.0 manual execution: execute(bytes encodedMessage, address[] ccvs, bytes[] verifierResults,
        # uint32 gasLimitOverride).
        "offRampExecute": "execute(bytes,address[],bytes[],uint32)",
    }
    for k, s in sigs.items():
        SEL[k] = _topic(s)[:10]


CHILD_ENV_KEYS = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TERM")
CHILD_ENV_PREFIXES = ("SCARB_", "MISE_", "XDG_")


def child_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """CSO D-3: signer children (cast, sncast) get a minimal allowlisted environment, not the parent's: no RPC, wallet,
    1Password or other credentials, plus only the explicit `extra` values."""
    env = {k: v for k, v in os.environ.items() if k in CHILD_ENV_KEYS or k.startswith(CHILD_ENV_PREFIXES)}
    return {**env, **(extra or {})}


def _memfd(name: str, data: bytes) -> int:
    fd = os.memfd_create(name, 0)
    os.write(fd, data)
    os.lseek(fd, 0, os.SEEK_SET)
    return fd


@dataclass
class Signer:
    """Signs with `cast mktx` from an encrypted keystore whose bytes match the bound sha256 (CSO D-2). The bytes are
    read and checked once (`freeze`), before any reservation and before any password access, and cast reads exactly
    those frozen bytes from an anonymous memfd, so swapping the file after the check changes nothing. The password
    goes through another memfd, never argv, env or disk."""

    keystore_dir: Path
    vault: str
    password_source: Callable[[str], bytes] = field(default=None)  # type: ignore[assignment]
    keystore_sha256: dict[str, str] = field(default_factory=dict)
    exe: str = "cast"
    timeout: float = 120
    frozen: dict[str, bytes] = field(default_factory=dict)

    def password(self, role: str) -> bytes:
        if self.password_source is not None:
            return self.password_source(role)
        if not self.vault:
            refuse("T2_OP_VAULT unset")
        return subprocess.run(["op", "read", f"op://{self.vault}/t2-{role}/password"], check=True,
                              capture_output=True).stdout.rstrip(b"\n")

    def freeze(self, role: str) -> bytes:
        want = self.keystore_sha256.get(role)
        if not _is_sha256(want):
            refuse(f"no bound keystore_sha256 for EVM role {role}: refused before any password access")
        ks = self.keystore_dir / f"t2-{role}.json"
        if not ks.is_file():
            refuse(f"keystore {ks} missing: keys are generated only after the key-preparation approval")
        data = ks.read_bytes()
        if sha256_hex(data) != want:
            refuse(f"EVM keystore {ks} differs from the bound keystore_sha256 for {role}: refused before any password "
                   "access")
        self.frozen[role] = data
        return data

    def sign(self, role: str, cid: int, tx: PlannedTx, max_fee: int, prio: int) -> str:
        data = self.frozen.get(role)
        if data is None:
            data = self.freeze(role)
        if sha256_hex(data) != self.keystore_sha256.get(role):
            refuse(f"frozen keystore for {role} differs from the bound keystore_sha256")
        # cast refuses pipes and process substitution for --password-file (it requires a regular file), so the
        # password goes into an anonymous in-memory file (memfd): never on disk, never in argv or the environment.
        k = _memfd("t2-keystore", data)
        r = os.memfd_create("t2-keystore-password", 0)
        try:
            pw = self.password(role)
            os.write(r, pw)
            os.lseek(r, 0, os.SEEK_SET)
            del pw
            args = [self.exe, "mktx", "--keystore", f"/dev/fd/{k}", "--password-file", f"/dev/fd/{r}", "--chain",
                    str(cid), "--nonce", str(tx.nonce), "--gas-limit", str(tx.gas), "--gas-price", str(max_fee),
                    "--priority-gas-price", str(prio), "--value", str(tx.value)]
            args += ["--create", tx.data] if tx.to is None else [tx.to, tx.data]
            proc = subprocess.Popen(args, pass_fds=(k, r), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=child_env())
            try:
                out, err = proc.communicate(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                # CSO D-3: never leave a hung signer running. The reservation stays unlinked (permanent stop, N-2).
                proc.kill()
                proc.communicate()
                raise
        finally:
            os.close(k)
            os.close(r)
        if proc.returncode != 0:
            refuse(f"cast mktx failed: {err.decode()[-300:]}")
        return out.decode().strip()


def decode_signed(raw: str) -> dict:
    out = subprocess.run(["cast", "decode-transaction", raw], check=True, capture_output=True, text=True).stdout
    j = json.loads(out)
    return json.loads(j) if isinstance(j, str) else j


def verify_signed(d: dict, cid: int, tx: PlannedTx, max_fee: int, prio: int) -> None:
    want = {
        "signer": tx.frm, "chainId": cid, "nonce": tx.nonce, "gas": tx.gas, "maxFeePerGas": max_fee,
        "maxPriorityFeePerGas": prio, "to": tx.to, "value": tx.value, "input": tx.data, "type": 2,
    }
    got = {
        "signer": d["signer"].lower(), "chainId": int(d["chainId"], 16), "nonce": int(d["nonce"], 16),
        "gas": int(d["gas"], 16), "maxFeePerGas": int(d["maxFeePerGas"], 16),
        "maxPriorityFeePerGas": int(d["maxPriorityFeePerGas"], 16), "to": (d.get("to") or None),
        "value": int(d["value"], 16), "input": d["input"].lower(), "type": int(d["type"], 16),
    }
    if got["to"]:
        got["to"] = got["to"].lower()
    for k, v in want.items():
        if got[k] != v:
            refuse(f"signed transaction field {k} = {got[k]} != expected {v}: not published")
    if d.get("accessList"):
        refuse("signed transaction carries an access list: not published")


def precheck(led: Ledger, lim: dict, cid: int, role: str, kind: str, tx: PlannedTx, base_fee: int,
             prio: int) -> tuple[int, int, int]:
    """Returns (max_fee_per_gas, priority, max_cost). Refuses before signing if any bound would be exceeded."""
    require_no_stop(led)
    c = lim["evm"][str(cid)]
    kd = c["kinds"].get(kind)
    if kd is None or kd["role"] != role:
        refuse(f"kind {kind} is not allowed for role {role} on chain {cid}")
    ceiling = int(c["gas_price_ceiling_wei"])
    if base_fee > ceiling:
        refuse(f"chain {cid}: base fee {base_fee} above the gas-price ceiling {ceiling}: stop")
    prio = min(prio, ceiling - base_fee) if base_fee < ceiling else 0
    max_fee = ceiling
    if tx.gas > int(kd["gas_max"]):
        refuse(f"{kind}: planned gas limit {tx.gas} above the per-transaction maximum {kd['gas_max']}")
    vmax = int(kd.get("value_max_wei", 0))
    if tx.value > vmax:
        refuse(f"{kind}: value {tx.value} above {vmax}")
    if led.kind_count(cid, kind) + 1 > int(kd["attempts_max"]):
        refuse(f"{kind}: attempt {led.kind_count(cid, kind) + 1} exceeds the {kd['attempts_max']} allowed "
               "(failed, reverted and replaced attempts count)")
    if len(led.attempts(cid)) + 1 > int(c["attempts_max"]):
        refuse(f"chain {cid}: attempt count cap {c['attempts_max']} reached")
    if led.open_reserves(cid):
        refuse(f"chain {cid}: an earlier attempt has an unknown outcome; run `reconcile` first")
    cost = tx.gas * max_fee + tx.value
    if led.exposure(cid, role) + cost > int(c["role_cap_wei"][role]):
        refuse(f"chain {cid} role {role}: spent+reserved {led.exposure(cid, role)} + candidate {cost} exceeds "
               f"{c['role_cap_wei'][role]}")
    if led.exposure(cid) + cost > int(c["chain_cap_wei"]):
        refuse(f"chain {cid}: spent+reserved {led.exposure(cid)} + candidate {cost} exceeds {c['chain_cap_wei']}")
    if kind == "dispatch":
        msgs, fees = led.ccip()
        if msgs + 1 > int(lim["ccip"]["messages_max"]):
            refuse("CCIP: the successful-message cap is reached; never dispatch beyond it")
        if fees + tx.value > int(lim["ccip"]["fee_total_wei"]):
            refuse("CCIP: total message fees would exceed the cap")
        if tx.value > int(lim["ccip"]["fee_max_wei"]):
            refuse("CCIP: message fee above the per-message maximum")
    return max_fee, prio, cost


def evm_intent(cid: int, role: str, addr: str, kind: str, step: str, tx: PlannedTx, max_fee: int, prio: int) -> dict:
    """The unsigned intent that is reserved durably before any signer runs; the signed bytes must match it."""
    return {"chain": cid, "role": role, "from": addr, "kind": kind, "step": step, "nonce": tx.nonce, "gas": tx.gas,
            "max_fee": max_fee, "priority": prio, "value": str(tx.value), "to": tx.to,
            "input_sha256": sha256_hex(bytes.fromhex(tx.data[2:]))}


def _no_fault(_point: str, _rec: dict) -> None:
    return None


def send_plan(led: Ledger, lim: dict, binding: dict, step: str, cid: int, role: str, plan: list[PlannedTx],
              chain: EvmChain, signer: Signer, dispatched_topic: str, out: Callable[[str], None] = print,
              fault: Callable[[str, dict], None] = _no_fault,
              decode: Callable[[str], dict] | None = None) -> None:
    """Per transaction: checks -> durable unsigned reservation -> sign -> verify -> durable `signed` link -> publish.

    CFO R1: the reservation (intent, nonce, role, kind, attempt count, maximum liability) is appended and fsync'd
    BEFORE the signer is invoked. A crash while signing or before the link leaves an unlinked open reservation that
    blocks every later attempt and is never released (N-2). Only an in-process refusal of the signer or of the
    signed-field comparison, where nothing was published and the bytes are discarded, closes the slot as `void`;
    the attempt still counts against the kind and chain attempt caps.
    """
    decode = decode or decode_signed
    addr = binding["roles"][role].lower()
    require_chain_ids({cid: chain})
    kinds = [classify(step, tx, binding, cid) for tx in plan]  # every tx classified before anything is signed
    for tx in plan:
        if tx.frm != addr:
            refuse(f"step {step}: planned broadcaster {tx.frm} is not the single unlocked role {role} ({addr})")
    signer.freeze(role)  # D-2: bound keystore bytes checked and frozen before any reservation or password access
    for tx, kind in zip(plan, kinds):
        latest, pending = chain.nonce(addr), chain.nonce(addr, "pending")
        if latest != pending or tx.nonce != latest or led.mined_count(cid, addr) != latest:
            refuse(f"{role} nonce: plan {tx.nonce}, latest {latest}, pending {pending}, ledger "
                   f"{led.mined_count(cid, addr)}: nonce ambiguity, stop")
        base_fee, prio0 = chain.base_fee(), chain.priority_fee()
        max_fee, prio, cost = precheck(led, lim, cid, role, kind, tx, base_fee, prio0)
        intent = evm_intent(cid, role, addr, kind, step, tx, max_fee, prio)
        rec = led.append({"type": "reserve", **intent, "max_cost": str(cost), "hash": "",
                          "attempt": led.kind_count(cid, kind) + 1,
                          "intent_sha256": sha256_hex(json.dumps(intent, sort_keys=True).encode())})
        fault("reserved", rec)
        try:
            raw = signer.sign(role, cid, tx, max_fee, prio)
            d = decode(raw)
            verify_signed(d, cid, tx, max_fee, prio)
        except Refused as e:
            led.append({"type": "void", "ref": rec["seq"], "chain": cid,
                        "reason": f"in-process refusal before publish (bytes discarded, never published): {e}"})
            raise
        fault("signed", rec)
        h0 = d["hash"].lower()
        led.append({"type": "signed", "ref": rec["seq"], "chain": cid, "hash": h0, "raw": raw,
                    "raw_sha256": sha256_hex(bytes.fromhex(raw[2:]))})
        fault("linked", rec)
        try:
            h = chain.publish(raw)
        except Exception as e:  # noqa: BLE001
            refuse(f"publish of {h0} failed ({e}); it stays reserved until `reconcile`")
        if h.lower() != h0:
            refuse(f"node returned hash {h} for signed {h0}")
        out(f"sent {kind} {h} (nonce {tx.nonce}, gas<= {tx.gas}, maxFee {max_fee}, reserved {cost})")
        rc = wait_receipt(chain, h, int(os.environ.get("T2_RECEIPT_TIMEOUT", "900")))
        if rc is None:
            refuse(f"no receipt for {h} yet: it stays reserved at {cost}; run `reconcile` before anything else")
        o = record_receipt(led, chain, rec, rc, dispatched_topic)
        if o["status"] != 1:
            refuse(f"{kind} {h} reverted (cost {o['cost']} counted): stop")


# ------------------------------------------------------------------------------------------------ stop conditions
def watch_evm(led: Ledger, binding: dict, chains: dict[int, EvmChain], sn_hashes_fn: Callable[[], set[str]] | None,
              topics: dict[str, str], out: Callable[[str], None] = print) -> None:
    p, r = binding["predicted"], binding["roles"]
    require_chain_ids(chains)
    for cid, chain in chains.items():
        for o in r["safe_owners"]:
            if chain.nonce(o) != 0:
                refuse(f"Safe signer {o} has sent a transaction on chain {cid}: stop")
    contracts = {
        SEPOLIA: [p["proxy"], p["sender"]],
        BNB_TESTNET: [p["executor_97"], p["safe_97"], *p["targets_97"]],
        MONAD_TESTNET: [p["executor_10143"], p["safe_10143"], *p["targets_10143"]],
    }
    executors = {p["executor_97"].lower(), p["executor_10143"].lower()}
    delivered = {topics["Pinged"], topics["Queued"]}
    payloads = led.dispatched_payloads()
    for cid, chain in chains.items():
        mined = led.mined_hashes(cid)
        start = min((o["block"] for o in led.records if o["type"] == "outcome" and o["chain"] == cid), default=None)
        if start is None:
            continue
        head = chain.block_number()
        chunk = 100 if cid == MONAD_TESTNET else 1000
        frm = max([w["to"] + 1 for w in led.records if w["type"] == "watch" and w["chain"] == cid] + [start])
        for addr in contracts[cid]:
            b = frm
            while b <= head:
                e = min(head, b + chunk - 1)
                for lg in chain.logs(addr, b, e):
                    t0 = lg["topics"][0].lower() if lg["topics"] else ""
                    if lg["address"].lower() in executors and t0 in delivered:
                        if lg["topics"][1].lower() not in payloads:
                            refuse(f"chain {cid}: executor {t0[:10]} for UNKNOWN payload {lg['topics'][1]}: the Safe "
                                   "cancels, T2 stops, CSO is notified")
                        continue
                    if lg["transactionHash"].lower() not in mined:
                        refuse(f"chain {cid}: log at {addr} from transaction {lg['transactionHash']} that is not in "
                               "the ledger (unknown request, message or call): stop")
                b = e + 1
        led.append({"type": "watch", "chain": cid, "from": frm, "to": head})
    if SEPOLIA in chains:
        executed = sum(1 for a in led.attempts(SEPOLIA) if a["kind"] == "l1-execute"
                       and (o := led.outcome(a["seq"])) is not None and o["type"] == "outcome" and o["status"] == 1)
        code = chains[SEPOLIA].rpc.call("eth_getCode", [p["proxy"], "latest"])
        if code not in ("0x", "0x0"):
            n = int(chains[SEPOLIA].call(p["proxy"], SEL_CURRENT_NONCE[0]), 16)
            if n != executed:
                refuse(f"proxy currentNonce {n} != ledger L1 executions {executed}: unknown L2 message consumed a "
                       "nonce: stop")


SEL_CURRENT_NONCE = [""]


SN_CONTRACT_NOT_FOUND, SN_TXN_HASH_NOT_FOUND = 20, 29  # exact Starknet JSON-RPC error codes (N-6)


class StarknetRpc:
    def __init__(self, url: str):
        self.rpc = Rpc(url)

    def chain_id(self) -> str:
        return self.rpc.call("starknet_chainId", [])

    def nonce(self, a: str) -> int:
        """Only the exact JSON-RPC error code 20 (CONTRACT_NOT_FOUND: undeployed account) means nonce 0 (N-6)."""
        try:
            return int(self.rpc.call("starknet_getNonce", ["latest", a]), 16)
        except RpcError as e:
            if e.code == SN_CONTRACT_NOT_FOUND:
                return 0
            refuse(f"Starknet getNonce error is not CONTRACT_NOT_FOUND (code {e.code}): {e}")
        return -1

    def receipt(self, h: str) -> dict | None:
        try:
            return self.rpc.call("starknet_getTransactionReceipt", [h])
        except RpcError as e:
            if e.code == SN_TXN_HASH_NOT_FOUND:
                return None
            refuse(f"Starknet getTransactionReceipt error (code {e.code}): {e}")
        return None

    def transaction(self, h: str) -> dict | None:
        try:
            return self.rpc.call("starknet_getTransactionByHash", [h])
        except RpcError as e:
            if e.code == SN_TXN_HASH_NOT_FOUND:
                return None
            refuse(f"Starknet getTransactionByHash error (code {e.code}): {e}")
        return None

    def events(self, address: str, frm: int, chunk_token: str | None = None) -> dict:
        f = {"address": address, "from_block": {"block_number": frm}, "to_block": "latest", "chunk_size": 1000,
             "keys": []}
        if chunk_token:
            f["continuation_token"] = chunk_token
        return self.rpc.call("starknet_getEvents", [f])

    def class_hash_at(self, a: str) -> int | None:
        """None only for the exact CONTRACT_NOT_FOUND code; any other error refuses."""
        try:
            return int(self.rpc.call("starknet_getClassHashAt", ["latest", a]), 16)
        except RpcError as e:
            if e.code == SN_CONTRACT_NOT_FOUND:
                return None
            refuse(f"Starknet getClassHashAt error (code {e.code}): {e}")
        return None


def require_sn_chain(sn: Any) -> None:
    """N-4 (Starknet): every Starknet RPC the guard reads, watches or reconciles must be Starknet Sepolia."""
    got = sn.chain_id()
    if got != SN_CHAIN_ID_SEPOLIA:
        refuse(f"Starknet RPC reports chain id {got}, not SN_SEPOLIA: stop")


def watch_starknet(led: Ledger, binding: dict, sn: StarknetRpc) -> None:
    require_sn_chain(sn)
    mined = led.mined_hashes(STARKNET_SEPOLIA)
    start = min((o["block"] for o in led.records if o["type"] == "outcome" and o["chain"] == STARKNET_SEPOLIA),
                default=None)
    if start is None:
        return
    s = binding["starknet"]
    for addr in (s["token"], s["staker"], s["governor"]):
        tok = None
        while True:
            page = sn.events(addr, start, tok)
            for ev in page["events"]:
                if int(ev["transaction_hash"], 16) not in {int(h, 16) for h in mined}:
                    refuse(f"Starknet: event at {addr} from transaction {ev['transaction_hash']} not in the ledger "
                           "(proposal, vote or stake by someone other than t2-starknet): stop")
            tok = page.get("continuation_token")
            if not tok:
                break


# ------------------------------------------------------------------------------------------------ Starknet sends
def sn_precheck(led: Ledger, lim: dict, kind: str) -> int:
    """Before the reservation (and so before any sncast run, dry-run included): returns the kind max fee, which is
    the reserved maximum liability."""
    require_no_stop(led)
    sn = lim["starknet"]
    kd = sn["kinds"].get(kind)
    if kd is None:
        refuse(f"Starknet kind {kind} is not in the approved schedule")
    cap = int(kd["max_fee_fri"])
    if led.kind_count(STARKNET_SEPOLIA, kind) + 1 > int(kd["attempts_max"]):
        refuse(f"Starknet {kind}: attempt cap {kd['attempts_max']} reached")
    retries = sum(max(0, led.kind_count(STARKNET_SEPOLIA, k) - int(v["planned"])) for k, v in sn["kinds"].items())
    if led.kind_count(STARKNET_SEPOLIA, kind) + 1 > int(kd["planned"]) and retries + 1 > int(sn["retries_max"]):
        refuse("Starknet: retry budget exhausted")
    if len(led.attempts(STARKNET_SEPOLIA)) + 1 > int(sn["attempts_max"]):
        refuse("Starknet: attempt count cap reached")
    if led.open_reserves(STARKNET_SEPOLIA):
        refuse("Starknet: an earlier attempt has an unknown outcome; run `reconcile` first")
    if led.exposure(STARKNET_SEPOLIA) + cap > int(sn["fee_cap_fri"]):
        refuse(f"Starknet: fees spent+reserved {led.exposure(STARKNET_SEPOLIA)} + {cap} exceed {sn['fee_cap_fri']}")
    return cap


SN_RESOURCES = ("l1_gas", "l2_gas", "l1_data_gas")
# (amount numerator, denominator, price numerator, denominator): the first margin whose liability fits the cap.
SN_MARGINS = ((3, 2, 2, 1), (3, 2, 3, 2), (5, 4, 5, 4), (1, 1, 1, 1))


def _int(v: Any) -> int:
    return int(v, 16) if isinstance(v, str) and v.startswith("0x") else int(v)


def sn_liability(bounds: dict, tip: int = 0) -> int:
    """Maximum fee a v3 transaction with these resource bounds can be charged: sum(max_amount x max_price) + tip x
    max L2 gas."""
    return sum(_int(bounds[r]["max_amount"]) * _int(bounds[r]["max_price_per_unit"]) for r in SN_RESOURCES) \
        + tip * _int(bounds["l2_gas"]["max_amount"])


def sn_bounds(est: dict, cap: int) -> dict:
    """Explicit resource bounds from the fresh estimate; their maximum liability never exceeds the reserved cap."""
    try:
        c = {k: _int(est[k]) for r in SN_RESOURCES for k in (f"{r}_consumed", f"{r}_price")}
    except (KeyError, TypeError, ValueError):
        refuse("sncast dry-run output lacks the per-resource estimate")
    for an, ad, pn, pd in SN_MARGINS:
        b = {r: {"max_amount": -(-c[f"{r}_consumed"] * an // ad), "max_price_per_unit": -(-c[f"{r}_price"] * pn // pd)}
             for r in SN_RESOURCES}
        if sn_liability(b) <= cap:
            return b
    base = {r: {"max_amount": c[f"{r}_consumed"], "max_price_per_unit": c[f"{r}_price"]} for r in SN_RESOURCES}
    refuse(f"Starknet fresh estimate {sn_liability(base)} above the per-tx maximum {cap}: stop and revise")
    return {}


def sn_bounds_argv(b: dict) -> list[str]:
    return ["--l1-gas", str(b["l1_gas"]["max_amount"]), "--l1-gas-price", str(b["l1_gas"]["max_price_per_unit"]),
            "--l2-gas", str(b["l2_gas"]["max_amount"]), "--l2-gas-price", str(b["l2_gas"]["max_price_per_unit"]),
            "--l1-data-gas", str(b["l1_data_gas"]["max_amount"]),
            "--l1-data-gas-price", str(b["l1_data_gas"]["max_price_per_unit"]), "--tip", "0"]


SN_UDC = "0x02ceed65a4bd731034c01113685c831b01c15d7d432f71afb1cf1634b53a2125"  # sncast 0.62.1 `deploy` (UDC v2)


def sn_selector(name: str) -> int:
    return int(cast_out("keccak", name), 16) & ((1 << 250) - 1)


def _tail_felts(args: list[str], flag: str) -> list[int]:
    return _felts(args[args.index(flag) + 1:]) if flag in args else []


def sn_expected(kind: str, args: list[str], binding: dict) -> dict:
    """The exact transaction this kind may produce (sn_validate has already bound the argv). Values are hex felts."""
    s, acct = binding["starknet"], int(binding["roles"]["starknet_account"], 16)
    h = lambda xs: [hex(x) for x in xs]  # noqa: E731
    if kind == "account-deploy":
        return {"type": "DEPLOY_ACCOUNT", "class_hash": hex(int(s["account_class_hash"], 16)),
                "contract_address_salt": hex(int(s["account_salt"], 16)),
                "constructor_calldata": h([int(s["account_public_key"], 16)]), "contract_address": hex(acct)}
    if kind in SN_DECLARE_NAME:
        return {"type": "DECLARE", "sender_address": hex(acct),
                "class_hash": hex(int(SN_CLASSES[kind.split("-", 1)[1]], 16))}
    if kind in SN_KIND_CONTRACT:
        ctor = _tail_felts(args, "--constructor-calldata")
        inner = [int(_opt(args, "--class-hash"), 16), int(_opt(args, "--salt"), 16), 1, len(ctor), *ctor]
        calldata = [1, int(SN_UDC, 16), sn_selector("deployContract"), len(inner), *inner]
    else:
        cd = _tail_felts(args, "--calldata")
        calldata = [1, int(_opt(args, "--contract-address"), 16), sn_selector(_opt(args, "--function")), len(cd), *cd]
    return {"type": "INVOKE", "sender_address": hex(acct), "calldata": h(calldata)}


def sn_verify_tx(tx: dict, rc: dict, a: dict, bounds: dict) -> None:
    """CFO R2: the transaction returned by the chain must be exactly the reserved intent (sender or deployed address,
    nonce, payload, type/version, resource bounds, tip, no paymaster/deployment data) before it is credited."""
    try:
        exp = a["expect"]
        if tx["type"] != exp["type"] or _int(tx["version"]) != 3:
            refuse(f"type/version {tx['type']}/{tx['version']} != {exp['type']}/0x3")
        if _int(tx["nonce"]) != int(a["nonce"]):
            refuse(f"nonce {tx['nonce']} != reserved {a['nonce']}")
        for k, v in exp.items():
            if k == "type":
                continue
            got = rc["contract_address"] if k == "contract_address" else tx[k]
            if isinstance(v, list):
                if [_int(x) for x in got] != [_int(x) for x in v]:
                    refuse(f"{k} differs from the reserved intent")
            elif _int(got) != _int(v):
                refuse(f"{k} {got} != {v}")
        for r in SN_RESOURCES:
            for f in ("max_amount", "max_price_per_unit"):
                if _int(tx["resource_bounds"][r][f]) != _int(bounds[r][f]):
                    refuse(f"resource bound {r}.{f} {tx['resource_bounds'][r][f]} != reserved {bounds[r][f]}")
        if _int(tx["tip"]) != 0 or tx["paymaster_data"] != []:
            refuse("tip or paymaster data set")
        if (tx["nonce_data_availability_mode"], tx["fee_data_availability_mode"]) != ("L1", "L1"):
            refuse("nonce/fee data availability mode is not L1 (CSO D-3)")
        if exp["type"] != "DEPLOY_ACCOUNT" and tx["account_deployment_data"] != []:
            refuse("account deployment data set")
        if sn_liability(tx["resource_bounds"], _int(tx["tip"])) > int(a["max_cost"]):
            refuse("signed maximum liability above the reservation")
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        refuse(f"missing or malformed field {e!s}")


def sn_settle(led: Ledger, sn: Any, a: dict) -> dict | None:
    """Credits a linked reservation only after the on-chain transaction matches it; None while still unknown."""
    h = led.tx_hash(a)
    if not h:
        refuse(f"Starknet reservation seq {a['seq']} ({a['kind']}, nonce {a['nonce']}) has no linked transaction hash "
               "(stopped during or right after sncast): unresolved, never released: permanent stop (N-2)")
    rc = sn.receipt(h)
    if not rc or rc.get("finality_status") not in ("ACCEPTED_ON_L2", "ACCEPTED_ON_L1"):
        return None
    tx = sn.transaction(h)
    if tx is None:
        return None
    bounds = next((r["bounds"] for r in led.records if r["type"] == "sn-bounds" and r["ref"] == a["seq"]), None)
    try:
        if bounds is None:
            refuse("no reserved resource bounds")
        sn_verify_tx(tx, rc, a, bounds)
        fee = rc["actual_fee"]
        if fee.get("unit") != "FRI":
            refuse(f"actual fee unit {fee.get('unit')} is not FRI")
        cost = _int(fee["amount"])
        status = 1 if rc["execution_status"] == "SUCCEEDED" else 0
        block = int(rc["block_number"])
    except Refused as e:
        led.append({"type": "incident", "ref": a["seq"], "chain": STARKNET_SEPOLIA, "hash": h,
                    "reason": f"returned transaction {h} does not match the reserved intent, not credited: {e}"})
        raise
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        led.append({"type": "incident", "ref": a["seq"], "chain": STARKNET_SEPOLIA, "hash": h,
                    "reason": f"receipt for {h} lacks a field ({e!s}), not credited"})
        refuse(f"Starknet receipt for {h} lacks a field ({e!s}): stop")
    o = led.append({"type": "outcome", "ref": a["seq"], "chain": STARKNET_SEPOLIA, "status": status, "cost": str(cost),
                    "block": block})
    if cost > int(a["max_cost"]):
        refuse(f"Starknet {a['kind']} {h}: actual fee {cost} above the reserved maximum {a['max_cost']} (recorded "
               "at its actual cost): stop (N-5)")
    return o


def sn_reconcile(led: Ledger, sn: StarknetRpc, account: str) -> None:
    require_sn_chain(sn)
    require_no_stop(led)
    for a in led.open_reserves(STARKNET_SEPOLIA):
        sn_settle(led, sn, a)
    n = sn.nonce(account)
    mined = sum(1 for a in led.attempts(STARKNET_SEPOLIA)
                if (o := led.outcome(a["seq"])) is not None and o["type"] == "outcome")
    if n != mined:
        refuse(f"Starknet account nonce {n} != ledger mined {mined}: unknown or unreconciled transaction: stop")


def sn_account_descriptor(binding: dict, deployed: bool) -> bytes:
    """CFO R2: the sncast account descriptor is generated from the bound public identity; an operator-supplied
    account file is never read, so it cannot be substituted. sncast's undeployed format has no address field; R2-D
    makes the class, salt and public key it carries derive exactly the bound address."""
    check_sn_account_binding(binding)
    s = binding["starknet"]
    dep = {"address": hex(int(binding["roles"]["starknet_account"], 16)), "class_hash": s["account_class_hash"],
           "status": "deployed"} if deployed else \
        {"class_hash": s["account_class_hash"], "salt": s["account_salt"], "status": "undeployed"}
    return json.dumps({"deployment": dep, "variant": {"legacy": False, "public_key": s["account_public_key"],
                                                      "type": "open_zeppelin", "version": 1}, "version": 1},
                      indent=2).encode()


def sn_check_identity(sn: Any, binding: dict, kind: str, keystore: bytes) -> bool:
    """Before any password or key access: keystore bytes, on-chain class and public key equal the bound identity.
    Returns whether the account is deployed. First (R2-D) the bound address must be the DEPLOY_ACCOUNT address derived
    from the bound class, salt and public key, so funding, descriptor and deploy all name one account."""
    check_sn_account_binding(binding)
    s, acct = binding["starknet"], binding["roles"]["starknet_account"]
    if sha256_hex(keystore) != s["keystore_sha256"]:
        refuse("Starknet keystore file differs from the bound keystore_sha256: refused before any password or key "
               "access")
    ch = sn.class_hash_at(acct)
    if kind == "account-deploy":
        if ch is not None:
            refuse(f"Starknet account {acct} already has code: account-deploy refused")
        return False
    if ch != int(s["account_class_hash"], 16):
        refuse(f"Starknet account {acct} class {ch if ch is None else hex(ch)} != bound {s['account_class_hash']}")
    if sn_call(sn, acct, "get_public_key") != [int(s["account_public_key"], 16)]:
        refuse(f"Starknet account {acct} on-chain public key != bound account_public_key")
    return True


@dataclass
class Sncast:
    """Runs sncast with the frozen keystore bytes and generated descriptor (anonymous memfds, never re-read from
    disk). The password is fetched only inside run(), i.e. after identity checks and the durable reservation."""

    keystore: bytes
    descriptor: bytes
    password_source: Callable[[], str]
    exe: str = "sncast"

    def run(self, args: list[str], cwd: Path | None = None) -> list[dict]:
        fds = []
        try:
            for name, data in (("t2-starknet-keystore", self.keystore), ("t2-starknet-account", self.descriptor)):
                fds.append(_memfd(name, data))
            pw = self.password_source()
            # sncast reads only this variable (CSO L-f: testnet only); everything else is the minimal env (D-3)
            env = child_env({"KEYSTORE_PASSWORD": pw})
            cmd = [self.exe, "--keystore", f"/dev/fd/{fds[0]}", "--account", f"/dev/fd/{fds[1]}", "--json", *args]
            p = subprocess.run(cmd, pass_fds=tuple(fds), capture_output=True, text=True, env=env, cwd=cwd)
            del pw, env
        finally:
            for fd in fds:
                os.close(fd)
        objs = [json.loads(line) for line in p.stdout.splitlines() if line.strip().startswith("{")]
        if p.returncode != 0 or any(o.get("type") == "error" for o in objs):
            refuse(f"sncast failed: {(p.stderr or p.stdout)[-400:]}")
        return objs


def sn_send(led: Ledger, lim: dict, binding: dict, kind: str, args: list[str], sn: Any, runner: Any,
            cwd: Path | None = None, out: Callable[[str], None] = print,
            fault: Callable[[str, dict], None] = _no_fault, polls: tuple[int, float] = (450, 2.0)) -> dict:
    """Starknet: reconcile + watch -> caps -> durable reservation of the kind max (with the exact expected tx) ->
    sncast dry-run -> explicit resource bounds (liability <= reservation, durable) -> sncast send with those bounds,
    tip 0 and --nonce -> link hash -> credit only a transaction that matches the reservation."""
    check_sn_account_binding(binding)  # R2-D: before any reservation or sncast run
    account = binding["roles"]["starknet_account"]
    require_sn_chain(sn)
    sn_reconcile(led, sn, account)
    watch_starknet(led, binding, sn)
    nonce = sn.nonce(account)
    cap = sn_precheck(led, lim, kind)
    rec = led.append({"type": "reserve", "chain": STARKNET_SEPOLIA, "role": "starknet", "from": account, "kind": kind,
                      "step": kind, "nonce": nonce, "value": "0", "max_cost": str(cap), "hash": "",
                      "attempt": led.kind_count(STARKNET_SEPOLIA, kind) + 1,
                      "argv_sha256": sha256_hex(" ".join(args).encode()), "expect": sn_expected(kind, args, binding),
                      "descriptor_sha256": sha256_hex(runner.descriptor), "keystore_sha256": sha256_hex(runner.keystore)})
    fault("reserved", rec)
    try:
        est = runner.run(args + ["--dry-run"], cwd)
        bounds = sn_bounds(next((o for o in est if "l2_gas_consumed" in o), {}), cap)
    except Refused as e:
        # A dry-run only signs a query-version transaction that the network never executes: nothing was sent.
        led.append({"type": "void", "ref": rec["seq"], "chain": STARKNET_SEPOLIA,
                    "reason": f"in-process refusal before any send (dry-run only): {e}"})
        raise
    led.append({"type": "sn-bounds", "ref": rec["seq"], "tip": "0", "max_liability": str(sn_liability(bounds)),
                "bounds": {r: {f: str(v) for f, v in b.items()} for r, b in bounds.items()}})
    fault("bounded", rec)
    opts = sn_bounds_argv(bounds) + ([] if kind == "account-deploy" else ["--nonce", str(nonce)])
    res = runner.run(args + opts, cwd)  # a failure here leaves the reservation unlinked: permanent stop (N-2)
    h = _find_hash(res)
    fault("signed", rec)
    led.append({"type": "sn-sent", "ref": rec["seq"], "hash": h})
    n, delay = polls
    for _ in range(n):
        o = sn_settle(led, sn, rec)
        if o is not None:
            if o["status"] != 1:
                refuse(f"Starknet {kind} {h} reverted (fee {o['cost']} counted): stop")
            out(f"Starknet {kind} {h} accepted, fee {o['cost']} fri (reserved {cap}, signed bounds "
                f"{sn_liability(bounds)})")
            return o
        time.sleep(delay)
    refuse(f"Starknet {kind} {h}: no receipt; stays reserved at {cap}")
    return {}


# ------------------------------------------------------------------------------------------------ CLI
def evm_chains(ids: tuple[int, ...] = EVM_CHAINS) -> dict[int, EvmChain]:
    return {cid: EvmChain(cid, rpc_url(cid)) for cid in ids}


def event_topics() -> dict[str, str]:
    return {
        "Pinged": _topic("Pinged(bytes32,bytes32,uint64)"),
        "Queued": _topic("Queued(bytes32,bytes32,uint64,uint64,uint64,bytes)"),
        "Dispatched": _topic("Dispatched(bytes32,uint64,bytes32,uint256,address)"),
    }


def evm_roles(b: dict) -> dict[str, str]:
    return {"deployer": b["roles"]["deployer"], "bootstrap": b["roles"]["bootstrap"], "payer": b["roles"]["payer"]}


def cmd_env(_: argparse.Namespace) -> None:
    scope, _lim, appr, env = authorize()
    for k, v in env.items():
        print(f"export {k}={shlex.quote(v)}")
    print(f"# scope digest {scope.digest} approved by {appr['approved_by']} ({appr['approval_ref']}) at head "
          f"{scope.head}; expires {appr['expires_at']}", file=sys.stderr)


def cmd_digest(_: argparse.Namespace) -> None:
    scope = compute_scope()
    lim = load_limits()
    print(json.dumps({"scope_digest": scope.digest, "manifest_sha256": scope.manifest_sha256,
                      "binding_sha256": scope.binding_sha256, "tooling_sha256": scope.tooling_sha256,
                      "head": scope.head, "binding_status": scope.binding.get("status"),
                      "limits": {"schema": lim["schema"]}}, indent=2))
    print("COMPUTED DIGEST: NOT AN APPROVAL. Only a human-approved record with stage final-transactions authorizes "
          "transactions.", file=sys.stderr)


def cmd_send(a: argparse.Namespace) -> None:
    scope, lim, _appr, env = authorize()
    _init_selectors()
    topics = event_topics()
    cid = int(a.chain)
    chains = evm_chains()
    sn = StarknetRpc(os.environ["STARKNET_SEPOLIA_RPC_URL"]) if os.environ.get("STARKNET_SEPOLIA_RPC_URL") else None
    if sn is None:
        refuse("STARKNET_SEPOLIA_RPC_URL unset (needed for the Governor stop conditions)")
    SEL_CURRENT_NONCE[0] = _topic("currentNonce()")[:10]
    with Ledger(ledger_path(scope.binding)) as led:
        reconcile_evm(led, chains, evm_roles(scope.binding), False, topics["Dispatched"])
        sn_reconcile(led, sn, scope.binding["roles"]["starknet_account"])
        watch_evm(led, scope.binding, chains, None, topics)
        watch_starknet(led, scope.binding, sn)
        plan = load_plan(Path(a.plan), cid)
        signer = Signer(Path(os.environ["T2_KEYSTORE_DIR"]), env["T2_OP_VAULT"],
                        keystore_sha256=dict(scope.binding["evm_keystore_sha256"]))
        send_plan(led, lim, scope.binding, a.step, cid, a.role, plan, chains[cid], signer, topics["Dispatched"],
                  fault=_fault_hook)
        watch_evm(led, scope.binding, chains, None, topics)


def cmd_preflight(_: argparse.Namespace) -> None:
    """Before any simulation: scope, unknown outcomes and nonce/ledger agreement (read-only; reconcile repairs)."""
    scope, _lim, _appr, _env = authorize()
    with Ledger(ledger_path(scope.binding)) as led:
        require_no_stop(led)
        if led.open_reserves():
            refuse("an earlier attempt has an unknown outcome; run `reconcile` first")
        chains = evm_chains()
        require_chain_ids(chains)
        for cid, ch in chains.items():
            for role, addr in evm_roles(scope.binding).items():
                if ch.nonce(addr) != led.mined_count(cid, addr):
                    refuse(f"chain {cid} {role}: on-chain nonce != ledger (deleted ledger, manual transaction or "
                           "lost receipt): stop")


FAULT_POINTS = ("reserved", "signed", "linked", "bounded")


def _fault_hook(point: str, _rec: dict) -> None:
    """Crash injection for the local fail-closed tests (T2_FAULT=<point>): it can only abort the process at a
    boundary after the durable reservation, never skip a check. `reserved`: before the signer runs; `signed`: after
    signing, before the durable link; `linked`: after the link, before publish; `bounded` (Starknet): after the
    dry-run bounds, before the send."""
    if os.environ.get("T2_FAULT") == point:
        os._exit(97)


def cmd_reconcile(a: argparse.Namespace) -> None:
    scope, _lim, _appr, _env = authorize()
    _init_selectors()
    topics = event_topics()
    with Ledger(ledger_path(scope.binding)) as led:
        reconcile_evm(led, evm_chains(), evm_roles(scope.binding), a.republish, topics["Dispatched"])
        if os.environ.get("STARKNET_SEPOLIA_RPC_URL"):
            sn_reconcile(led, StarknetRpc(os.environ["STARKNET_SEPOLIA_RPC_URL"]),
                         scope.binding["roles"]["starknet_account"])
        print("reconciled; open reservations:", len(led.open_reserves()))


def cmd_status(_: argparse.Namespace) -> None:
    scope = compute_scope(require_clean=False)
    lim = load_limits()
    p = ledger_path(scope.binding) if scope.binding.get("status") == "BOUND" else None
    if p is None or not p.exists():
        print("no ledger")
        return
    led = Ledger(p)
    led._load()
    for cid in EVM_CHAINS:
        c = lim["evm"][str(cid)]
        print(f"chain {cid}: attempts {len(led.attempts(cid))}/{c['attempts_max']}, exposure {led.exposure(cid)}/"
              f"{c['chain_cap_wei']} wei, open {len(led.open_reserves(cid))}")
    print("ccip (messages, fees):", led.ccip())
    print(f"starknet: attempts {len(led.attempts(STARKNET_SEPOLIA))}, fees {led.exposure(STARKNET_SEPOLIA)} fri")
    for (chain, role), r in sorted(faucet_register(led).items()):
        print(f"faucet {chain}/{role}: requests {r['requests']}, pending {r['pending']}, denied {r['denied']}, "
              f"received {r['received_count']} ({r['received']} native units)")
    for i in led.incidents():
        print(f"INCIDENT seq {i['seq']}: {i['reason']}")


def op_password(vault: str, item: str) -> Callable[[], str]:
    def read() -> str:
        if not vault:
            refuse("T2_OP_VAULT unset")
        return subprocess.run(["op", "read", f"op://{vault}/{item}/password"], check=True, capture_output=True,
                              text=True).stdout.rstrip("\n")
    return read


def cmd_sn(a: argparse.Namespace) -> None:
    """Starknet send through the guard; see sn_send. The account identity is checked before any password access."""
    scope, lim, _appr, env = authorize()
    url = os.environ["STARKNET_SEPOLIA_RPC_URL"]
    sn = StarknetRpc(url)
    args = a.sncast
    if args and args[0] == "--":
        args = args[1:]
    sn_run(scope.binding, lim, a.kind, args, sn, url, Path(os.environ["T2_KEYSTORE_DIR"]) / "t2-starknet.json",
           lambda: op_password(env["T2_OP_VAULT"], "t2-starknet"), ledger_path(scope.binding), fault=_fault_hook)
    if a.kind in SN_KIND_CONTRACT:
        print("\n".join(sn_check_deployment(sn, scope.binding, SN_KIND_CONTRACT[a.kind])))


def sn_run(binding: dict, lim: dict, kind: str, args: list[str], sn: Any, url: str, keystore_path: Path,
           password_factory: Callable[[], Callable[[], str]], ledger: Path, exe: str = "sncast",
           fault: Callable[[str, dict], None] = _no_fault, polls: tuple[int, float] = (450, 2.0)) -> dict:
    """The `sn` command after authorization. Order: chain id, argv shape, R2-D derived account address, keystore
    digest, on-chain identity; only then is the password source constructed (it is first CALLED inside the sncast
    dry-run, after the durable reservation)."""
    require_sn_chain(sn)
    check_sn_account_binding(binding)
    sn_validate(kind, args, binding, url)
    keystore = keystore_path.read_bytes()
    deployed = sn_check_identity(sn, binding, kind, keystore)
    runner = Sncast(keystore, sn_account_descriptor(binding, deployed), password_factory(), exe)
    cwd = repo_root() / SN_CONTRACTS[kind.split("-", 1)[1]][1] if kind in SN_DECLARE_NAME else None
    with Ledger(ledger) as led:
        return sn_send(led, lim, binding, kind, args, sn, runner, cwd=cwd, fault=fault, polls=polls)


def cmd_sn_check(_: argparse.Namespace) -> None:
    scope = compute_scope()
    check_binding(scope.binding, load_limits())
    sn = StarknetRpc(os.environ["STARKNET_SEPOLIA_RPC_URL"])
    require_sn_chain(sn)
    print("\n".join(sn_check_deployment(sn, scope.binding)))


# ------------------------------------------------------------------------------------------------ faucet register
FAUCET_STATUSES = ("requested", "received", "denied")


def faucet_register(led: Ledger) -> dict[tuple[str, str], dict]:
    """Cumulative per chain and role: requests, pending (requested, no terminal record), denied, received."""
    out: dict[tuple[str, str], dict] = {}
    reqs = {r["seq"]: r for r in led.records if r["type"] == "faucet" and r["status"] == "requested"}
    done = {r["ref"]: r for r in led.records if r["type"] == "faucet" and r["status"] != "requested"}
    for seq, r in reqs.items():
        e = out.setdefault((r["chain"], r["role"]), {"requests": 0, "pending": 0, "denied": 0, "received_count": 0,
                                                     "received": 0})
        e["requests"] += 1
        t = done.get(seq)
        if t is None:
            e["pending"] += 1
        elif t["status"] == "denied":
            e["denied"] += 1
        else:
            e["received_count"] += 1
            e["received"] += int(t["amount"])
    return out


def faucet_record(led: Ledger, binding: dict, chain: str, role: str, source: str, status: str, amount: int = 0,
                  ref: int | None = None, evidence: str = "") -> dict:
    """F4: one request per bound free source, chain and recipient, ever; no new request while one is pending;
    receipts are recorded truthfully and anything above the recipient max stops T2 (no reallocation or top-up)."""
    if status not in FAUCET_STATUSES:
        refuse(f"faucet status {status}")
    rcp = next((f for f in binding["funding_recipients"] if f["chain"] == chain and f["role"] == role), None)
    if rcp is None:
        refuse(f"faucet: {chain}/{role} is not a bound funding recipient")
    if not any(f["chain"] == chain and f["source"] == source for f in binding["faucet_sources"]):
        refuse(f"faucet: {source} is not a bound free source for {chain}")
    reg = faucet_register(led).get((chain, role), {"pending": 0, "received": 0})
    if status == "requested":
        if any(r["type"] == "faucet" and r["status"] == "requested" and (r["chain"], r["role"], r["source"]) ==
               (chain, role, source) for r in led.records):
            refuse(f"faucet: {source} was already requested for {chain}/{role} (one request per source, chain and "
                   "recipient, including denied ones)")
        if reg["pending"]:
            refuse(f"faucet: a request for {chain}/{role} is still pending: no repeat")
        if reg["received"] >= int(rcp["max"]):
            refuse(f"faucet: {chain}/{role} already holds its maximum")
        return led.append({"type": "faucet", "chain": chain, "role": role, "source": source, "status": status,
                           "evidence": evidence})
    req = next((r for r in led.records if r["type"] == "faucet" and r["seq"] == ref and r["status"] == "requested"
                and (r["chain"], r["role"], r["source"]) == (chain, role, source)), None)
    if req is None or any(r["type"] == "faucet" and r.get("ref") == ref for r in led.records):
        refuse("faucet: the result must reference one open request for the same source, chain and recipient")
    if status == "received" and amount <= 0:
        refuse("faucet: received amount must be positive")
    rec = led.append({"type": "faucet", "ref": ref, "chain": chain, "role": role, "source": source, "status": status,
                      "amount": str(amount if status == "received" else 0), "evidence": evidence})
    if status == "received" and reg["received"] + amount > int(rcp["max"]):
        led.append({"type": "incident", "ref": rec["seq"], "chain": chain,
                    "reason": f"faucet receipt for {chain}/{role} exceeds its bound maximum {rcp['max']}"})
        refuse(f"faucet: {chain}/{role} received above its maximum {rcp['max']} (recorded): stop, no reallocation")
    return rec


def cmd_faucet(a: argparse.Namespace) -> None:
    scope, _lim, _appr, _env = authorize()
    with Ledger(ledger_path(scope.binding)) as led:
        faucet_record(led, scope.binding, a.chain, a.role, a.source, a.status, int(a.amount or 0),
                      int(a.ref) if a.ref is not None else None, a.evidence or "")
        print(json.dumps({f"{c}/{r}": v for (c, r), v in faucet_register(led).items()}, indent=2))


def _find(objs: Any, keys: tuple[str, ...]) -> Any:
    for o in objs:
        for k in keys:
            if isinstance(o, dict) and k in o:
                return o[k]
    refuse(f"sncast output lacks {keys}")


def _find_hash(objs: Any) -> str:
    h = str(_find(objs, ("transaction_hash",)))
    try:
        if not h.startswith("0x") or int(h, 16) == 0:
            raise ValueError
    except ValueError:
        refuse(f"sncast returned a malformed transaction hash {h!r}")
    return h


# Starknet `selector!("send_message_to_l1")` = starknet_keccak (== T2Config.SEND_MESSAGE_TO_L1_SELECTOR).
SN_CHAIN_ID_SEPOLIA = "0x534e5f5345504f4c4941"
SN_SIGNER_OPTS = ("--max-fee", "-m", "--nonce", "-n", "--l1-gas", "--l1-gas-price", "--l2-gas", "--l2-gas-price",
                  "--l1-data-gas", "--l1-data-gas-price", "--tip", "--estimate-tip", "--account", "-a", "--keystore",
                  "-k", "--accounts-file", "-f", "--network", "--wait", "-w", "--wait-timeout", "--wait-retry-interval",
                  "--dry-run", "--detailed", "--json", "-j", "--profile", "-p", "--proof-file", "--proof-facts-file")
SN_KIND_CONTRACT = {"deploy-token": "token", "deploy-staker": "staker", "deploy-governor": "governor"}
SN_DECLARE_NAME = {"declare-token": "T2VotingToken", "declare-staker": "governance::staker::Staker",
                   "declare-governor": "Governor"}


def send_message_selector() -> int:
    k = int(cast_out("keccak", "send_message_to_l1"), 16)
    return k & ((1 << 250) - 1)


def _opt(args: list[str], name: str) -> str:
    if args.count(name) != 1:
        refuse(f"Starknet argv: exactly one {name} required")
    i = args.index(name)
    if i + 1 >= len(args):
        refuse(f"Starknet argv: {name} without a value")
    return args[i + 1]


def _felts(vals: list[str]) -> list[int]:
    try:
        return [int(v, 0) for v in vals]
    except ValueError:
        refuse("Starknet argv: calldata must be integers")
    return []


def sn_check_calls(felts: list[int], binding: dict) -> None:
    """A Governor call list may only contain `send_message_to_l1(T2 proxy, payload)` calls on the T2 Governor."""
    gov = int(binding["starknet"]["governor"], 16)
    proxy = int(binding["predicted"]["proxy"], 16)
    sel = send_message_selector()
    if not felts or not 1 <= felts[0] <= 2:
        refuse("Starknet calls: 1 or 2 calls per proposal")
    i, n = 1, felts[0]
    for _ in range(n):
        if i + 3 > len(felts):
            refuse("Starknet calls: truncated call")
        to, s, ln = felts[i], felts[i + 1], felts[i + 2]
        cd = felts[i + 3:i + 3 + ln]
        if to != gov or s != sel:
            refuse("Starknet calls: only send_message_to_l1 on the T2 Governor is allowed")
        if len(cd) != ln or ln < 2 or cd[0] != proxy or cd[1] != ln - 2:
            refuse("Starknet calls: message must be addressed to the bound T2 proxy with a consistent length")
        i += 3 + ln
    if i != len(felts):
        refuse("Starknet calls: trailing felts")


def sn_validate(kind: str, args: list[str], binding: dict, url: str) -> None:
    """The exact sncast argv shape allowed per schedule kind; anything else is refused before an estimate is made."""
    for o in SN_SIGNER_OPTS:
        if o in args:
            refuse(f"Starknet argv: {o} is set by the guard only")
    s = binding["starknet"]
    acct = int(binding["roles"]["starknet_account"], 16)
    if kind == "account-deploy":
        if args[:2] != ["account", "deploy"] or _opt(args, "--url") != url or len(args) != 4:
            refuse("Starknet account-deploy argv")
        return
    if _opt(args, "--url") != url:
        refuse("Starknet argv: --url must be STARKNET_SEPOLIA_RPC_URL")
    if kind in SN_DECLARE_NAME:
        if args[0] != "declare" or _opt(args, "--contract-name") != SN_DECLARE_NAME[kind] or len(args) != 5:
            refuse(f"Starknet {kind} argv")
        sn_class_hash(kind.split("-", 1)[1])  # the local build must hash to the pinned class
        return
    if kind in SN_KIND_CONTRACT:
        c = SN_KIND_CONTRACT[kind]
        if args[0] != "deploy" or int(_opt(args, "--class-hash"), 16) != int(SN_CLASSES[c], 16) \
                or _opt(args, "--salt") != SN_SALT or "--unique" not in args:
            refuse(f"Starknet {kind} argv: class hash, salt or --unique")
        cd = _felts(args[args.index("--constructor-calldata") + 1:]) if "--constructor-calldata" in args else []
        want = {"token": [acct], "staker": [int(s["token"], 16)],
                "governor": [int(s["staker"], 16), *(int(v) for v in SN_GOVERNOR_CONFIG)]}[c]
        if cd != want:
            refuse(f"Starknet {kind}: constructor calldata differs from the bound addendum")
        return
    if args[0] != "invoke":
        refuse(f"Starknet {kind}: invoke expected")
    to, fn = int(_opt(args, "--contract-address"), 16), _opt(args, "--function")
    cd = _felts(args[args.index("--calldata") + 1:]) if "--calldata" in args else []
    stake = int(s["stake_amount"])
    if kind == "approve":
        ok = to == int(s["token"], 16) and fn == "approve" and cd == [int(s["staker"], 16), stake % (1 << 128),
                                                                      stake >> 128]
    elif kind == "stake":
        ok = to == int(s["staker"], 16) and fn == "stake_amount" and cd == [acct, stake]
    elif kind == "propose":
        ok = to == int(s["governor"], 16) and fn == "propose"
        if ok:
            sn_check_calls(cd, binding)
    elif kind == "vote":
        ok = to == int(s["governor"], 16) and fn == "vote" and len(cd) == 2 and cd[1] == 1
    elif kind.startswith("execute-"):
        ok = to == int(s["governor"], 16) and fn == "execute" and len(cd) >= 2
        if ok:
            sn_check_calls(cd[1:], binding)
    else:
        ok = False
    if not ok:
        refuse(f"Starknet {kind}: target, function or calldata differs from the bound addendum")


def sn_call(sn: "StarknetRpc", to: str, fn: str, calldata: list[str] | None = None) -> list[int]:
    sel = "0x%x" % (int(cast_out("keccak", fn), 16) & ((1 << 250) - 1))
    r = sn.rpc.call("starknet_call", [{"contract_address": to, "entry_point_selector": sel,
                                       "calldata": calldata or []}, "latest"])
    return [int(x, 16) for x in r]


def sn_check_deployment(sn: "StarknetRpc", binding: dict, upto: str = "governor") -> list[str]:
    """CSO L-b: exact class hashes, token supply/holder, Staker token, Governor staker and config tuple."""
    s, acct = binding["starknet"], binding["roles"]["starknet_account"]
    out = []
    order = ("token", "staker", "governor")
    for c in order[:order.index(upto) + 1]:
        h = sn.class_hash_at(s[c])
        if h != int(SN_CLASSES[c], 16):
            refuse(f"Starknet {c} {s[c]} class hash {h if h is None else hex(h)} != pinned {SN_CLASSES[c]}")
        out.append(f"{c} {s[c]} class {SN_CLASSES[c]} OK")
    supply = int(s["stake_amount"])
    if sn_call(sn, s["token"], "totalSupply") != [supply % (1 << 128), supply >> 128]:
        refuse("Starknet token: totalSupply differs from the bound fixed supply")
    out.append("token totalSupply OK")
    if upto in ("staker", "governor") and sn_call(sn, s["staker"], "get_token") != [int(s["token"], 16)]:
        refuse("Starknet staker: get_token is not the bound T2 token")
    if upto == "governor":
        if sn_call(sn, s["governor"], "get_staker") != [int(s["staker"], 16)]:
            refuse("Starknet governor: get_staker is not the bound T2 staker")
        if sn_call(sn, s["governor"], "get_config") != [int(v) for v in SN_GOVERNOR_CONFIG]:
            refuse("Starknet governor: get_config differs from the pinned T2 config tuple")
        out.append("governor get_staker + get_config OK")
    _ = acct
    return out


# ------------------------------------------------------------------------------------------------ binding (addendum)
SAFE_SINGLETON = "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"
SAFE_FALLBACK = "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
SN_CLASSES = {
    "token": "0x03c9587aec2a445af1ab5b8876287c7358cfa293bccaa8c20ddb54392bd0ff44",
    "staker": "0x0244c2213a85dc27cb4f966a6ce48be0b7d38aafad6882ca063a2da97f09dade",
    "governor": "0x044e2e3d2ae1b0415450b2b5d417698ce495f7ef500826ddb48a61f9dfe67401",
}
SN_SALT = "0x1232"
# Governor T2 config: voting_start_delay 60, voting_period 600, smoothing 60, quorum 1e18, threshold 1e18,
# execution delay 60, execution window 7 d (u128 values serialize as one felt each).
SN_GOVERNOR_CONFIG = ["60", "600", "60", "1000000000000000000", "1000000000000000000", "60", "604800"]


def cast_out(*args: str) -> str:
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def create_addr(deployer: str, nonce: int) -> str:
    return cast_out("compute-address", "--nonce", str(nonce), deployer).split()[-1]


def safe_addr(owners: list[str], salt_nonce: int, proxy_creation_code: str) -> str:
    init = cast_out("calldata", "setup(address[],uint256,address,bytes,address,address,uint256,address)",
                    "[" + ",".join(owners) + "]", "2", "0x" + "0" * 40, "0x", SAFE_FALLBACK, "0x" + "0" * 40, "0",
                    "0x" + "0" * 40)
    salt = cast_out("keccak", cast_out("concat-hex", cast_out("keccak", init), "0x%064x" % salt_nonce))
    init_hash = cast_out("keccak", cast_out("concat-hex", proxy_creation_code,
                                            "0x" + SAFE_SINGLETON[2:].lower().rjust(64, "0")))
    return cast_out("compute-address", SAFE_FACTORY, "--salt", salt, "--init-code-hash", init_hash).split()[-1]


SN_CONTRACTS = {  # (contract name, Scarb package directory relative to the repository root)
    "token": ("T2VotingToken", "l1_proxy/script/t2/cairo"),
    "staker": ("governance::staker::Staker", "."),
    "governor": ("Governor", "."),
}


def _sncast_util(kind: str, *args: str) -> str:
    name, pkg = SN_CONTRACTS[kind]
    out = subprocess.run(["sncast", "utils", *args, "--contract-name", name], cwd=repo_root() / pkg, check=True,
                         capture_output=True, text=True).stdout
    return out


def sn_class_hash(kind: str) -> str:
    out = _sncast_util(kind, "class-hash")
    h = "0x" + out.split("Class Hash:")[1].split()[0][2:].lower().rjust(64, "0")
    if int(h, 16) != int(SN_CLASSES[kind], 16):
        refuse(f"local {kind} class hash {h} != pinned {SN_CLASSES[kind]}")
    return h


def sn_addr(kind: str, calldata: list[str], account: str) -> str:
    sn_class_hash(kind)
    out = _sncast_util(kind, "contract-address", "--salt", SN_SALT, "--unique", "--deployer-address", account,
                       "--constructor-calldata", *calldata)
    return "0x" + out.split("Contract Address:")[1].split()[0][2:].lower().rjust(64, "0")


def build_binding(keys: dict, lim: dict, proxy_creation_code: str) -> dict:
    d, owners = keys["deployer"], keys["safe_owners"]
    acct = keys["starknet_account"].lower()
    ident = {"account_public_key": keys.get("starknet_public_key"), "account_class_hash":
             keys.get("starknet_account_class_hash"), "account_salt": keys.get("starknet_account_salt")}
    if _felt(acct, "starknet_account") != sn_account_address(ident):  # R2-D, before anything is derived from it
        refuse(f"keys: starknet_account {acct} is not the DEPLOY_ACCOUNT address of the given class, salt and "
               "public key")
    token = sn_addr("token", [acct], acct)
    staker = sn_addr("staker", [token], acct)
    governor = sn_addr("governor", [staker, *SN_GOVERNOR_CONFIG], acct)
    safe = safe_addr(owners, 1232, proxy_creation_code)
    caps = {int(c): v["role_cap_wei"] for c, v in lim["evm"].items()}
    b = {
        "schema": "ekubo-t2-binding-v1",
        "status": "BOUND",
        "note": "EKU-1261 T2 address-binding addendum. Computing it approves nothing; only a human-approved record "
                "with stage final-transactions over the exact scope digest authorizes transactions.",
        "op_vault": keys["op_vault"],
        "roles": {"deployer": d, "bootstrap": keys["bootstrap"], "payer": keys["payer"], "safe_owners": owners,
                  "starknet_account": acct},
        "safe_salt": "1232",
        "ledger_dir": keys["ledger_dir"],
        "evm_keystore_sha256": {r: str(v or "").lower() for r, v in (keys.get("evm_keystore_sha256") or {}).items()},
        "starknet": {"account": acct, "account_public_key": keys["starknet_public_key"].lower(),
                     "account_class_hash": keys["starknet_account_class_hash"].lower(),
                     "account_salt": keys["starknet_account_salt"].lower(), "account_type": "open_zeppelin",
                     "keystore_sha256": keys["starknet_keystore_sha256"].lower(),
                     "token": token, "staker": staker, "governor": governor,
                     "classes": SN_CLASSES, "salt": SN_SALT, "governor_config": SN_GOVERNOR_CONFIG,
                     "stake_amount": lim["starknet"]["stake_amount"]},
        "predicted": {
            "proxy": create_addr(d, 0), "sender": create_addr(d, 1),
            "targets_97": [create_addr(d, i) for i in range(2)], "safe_97": safe, "executor_97": create_addr(d, 3),
            "targets_10143": [create_addr(d, i) for i in range(4)], "safe_10143": safe,
            "executor_10143": create_addr(d, 5),
        },
        "limits": {"ccip_fee_max_wei": lim["ccip"]["fee_max_wei"]},
        "funding_recipients": [
            {"chain": f"eip155:{cid}", "role": r, "address": keys[r], "max": str(v)}
            for cid, rc in caps.items() for r, v in rc.items()
        ] + [{"chain": f"starknet:{STARKNET_SEPOLIA}", "role": "starknet", "address": acct,
              "max": lim["starknet"]["balance_cap_fri"]}],
        "faucet_sources": keys.get("faucet_sources", []),
    }
    check_binding(b, lim)
    return b


def cmd_bind(a: argparse.Namespace) -> None:
    keys = json.loads(Path(a.keys).read_text())
    lim = load_limits()
    code = os.environ.get("T2_SAFE_PROXY_CREATION_CODE") or cast_out(
        "call", "--rpc-url", rpc_url(BNB_TESTNET), SAFE_FACTORY, "proxyCreationCode()(bytes)")
    b = build_binding(keys, lim, code)
    text = json.dumps(b, indent=2) + "\n"
    Path(a.out).write_text(text)
    print(f"wrote {a.out} (sha256 {sha256_hex(text.encode())}); NOT AN APPROVAL", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="t2_guard.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("digest").set_defaults(f=cmd_digest)
    sp.add_parser("env").set_defaults(f=cmd_env)
    s = sp.add_parser("send")
    s.add_argument("--step", required=True)
    s.add_argument("--chain", required=True)
    s.add_argument("--role", required=True, choices=("deployer", "bootstrap", "payer"))
    s.add_argument("--plan", required=True)
    s.set_defaults(f=cmd_send)
    r = sp.add_parser("reconcile")
    r.add_argument("--republish", action="store_true")
    r.set_defaults(f=cmd_reconcile)
    sp.add_parser("status").set_defaults(f=cmd_status)
    bd = sp.add_parser("bind")
    bd.add_argument("--keys", required=True, help="JSON of the PUBLIC addresses only (no key material)")
    bd.add_argument("--out", default=str(BINDING))
    bd.set_defaults(f=cmd_bind)
    n = sp.add_parser("sn")
    n.add_argument("--kind", required=True)
    n.add_argument("sncast", nargs=argparse.REMAINDER)
    n.set_defaults(f=cmd_sn)
    sp.add_parser("sn-check").set_defaults(f=cmd_sn_check)
    sp.add_parser("preflight").set_defaults(f=cmd_preflight)
    fc = sp.add_parser("faucet", help="record a faucet request or its result in the cumulative register")
    fc.add_argument("--chain", required=True)
    fc.add_argument("--role", required=True)
    fc.add_argument("--source", required=True)
    fc.add_argument("--status", required=True, choices=FAUCET_STATUSES)
    fc.add_argument("--amount")
    fc.add_argument("--ref")
    fc.add_argument("--evidence")
    fc.set_defaults(f=cmd_faucet)
    a = ap.parse_args(argv)
    if os.environ.get("T2_MODE") not in (None, "", "testnet") and a.cmd in ("send", "sn", "reconcile"):
        print("refused: signing commands run only with T2_MODE=testnet", file=sys.stderr)
        return 3
    try:
        a.f(a)
    except Refused as e:
        print(f"REFUSED (nothing further signed or sent): {e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
