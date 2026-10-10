#!/usr/bin/env python3
"""EKU-1261 T2 guard (TESTNET ONLY): the only component that signs or sends a T2 transaction.

It binds every T2 signing step to the approved scope, the bound addresses and a durable spend ledger:

* scope (T2-3): the canonical scope digest = sha256 over the manifest, the binding addendum and every tooling file is
  recomputed from a clean git tree and compared with the committed approval record `binding/t2-approval.json`
  (stage `final-transactions`, unexpired). Environment variables never approve anything; identities, Safe salt,
  Governor felt and fee cap are exported FROM the bound addendum, and a conflicting pre-set value is refused.
* ledger (F1): an append-only, hash-chained, fsync'd JSONL ledger under an exclusive non-blocking lock. Before a
  transaction is published, its maximum liability (gas limit x max fee per gas + value, or the Starknet max fee) is
  reserved and checked against cumulative per-chain, per-role, per-kind count, message and fee limits. Failed,
  reverted, replaced and manual attempts count. Unknown outcomes stay reserved at their maximum until reconciled from
  a receipt. On-chain nonces of every role must equal the ledger's mined count, so a deleted ledger, a manual
  transaction or a lost receipt fails closed.
* pre-sign (F1): each planned EVM transaction is signed with `cast mktx` (encrypted keystore, password streamed from
  1Password through a pipe), decoded with `cast decode-transaction`, and every signed field (signer, chain, nonce,
  to, value, input, gas, max fee, priority fee) is compared with the simulated plan and the limits BEFORE
  `cast publish`. Fresh base fee and nonce are read immediately before signing.
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
             "T2_BINDING_JSON", "T2_BINDING_SHA256", "T2_SCOPE_DIGEST")


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
            raise RuntimeError(f"{method}: {out['error']}")
        return out["result"]


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

    def tx_hash(self, a: dict) -> str:
        """EVM hashes are known before publishing; Starknet hashes are linked by a later `sn-sent` record."""
        if a.get("hash"):
            return a["hash"].lower()
        for r in self.records:
            if r["type"] == "sn-sent" and r["ref"] == a["seq"]:
                return r["hash"].lower()
        return ""

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
    base = Path(os.environ.get("T2_LEDGER_DIR") or Path.home() / ".local/state/ekubo-t2")
    ident = sha256_hex(json.dumps(binding["roles"], sort_keys=True).encode())[:16]
    return base / f"ledger-{ident}.jsonl"


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
    if rc["from"].lower() != a["from"].lower() or rc["transactionHash"].lower() != a["hash"].lower():
        refuse(f"receipt for {a['hash']} does not match the reserved signer or hash")
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
    for cid, chain in chains.items():
        for a in led.open_reserves(cid):
            rc = chain.receipt(a["hash"])
            if rc is None and republish:
                try:
                    chain.publish(a["raw"])  # identical signed bytes: same hash, no new liability
                    out(f"republished reserved tx {a['hash']} (seq {a['seq']})")
                except Exception as e:  # noqa: BLE001
                    out(f"republish of {a['hash']} failed: {e}")
                rc = wait_receipt(chain, a["hash"], 180)
            if rc is not None:
                record_receipt(led, chain, a, rc, dispatched_topic)
                continue
            if chain.nonce(a["from"]) > int(a["nonce"]):
                twin = [b for b in led.attempts(cid) if b["from"].lower() == a["from"].lower()
                        and b["nonce"] == a["nonce"] and b["seq"] != a["seq"] and chain.receipt(b["hash"])]
                if twin:
                    led.append({"type": "void", "ref": a["seq"], "chain": cid, "reason": f"nonce mined by {twin[0]['hash']}"})
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


@dataclass
class Signer:
    """Signs with `cast mktx` from an encrypted keystore; the password goes through a pipe fd, never argv or env."""

    keystore_dir: Path
    vault: str
    password_source: Callable[[str], bytes] = field(default=None)  # type: ignore[assignment]

    def password(self, role: str) -> bytes:
        if self.password_source is not None:
            return self.password_source(role)
        if not self.vault:
            refuse("T2_OP_VAULT unset")
        return subprocess.run(["op", "read", f"op://{self.vault}/t2-{role}/password"], check=True,
                              capture_output=True).stdout.rstrip(b"\n")

    def sign(self, role: str, cid: int, tx: PlannedTx, max_fee: int, prio: int) -> str:
        ks = self.keystore_dir / f"t2-{role}.json"
        if not ks.is_file():
            refuse(f"keystore {ks} missing: keys are generated only after the key-preparation approval")
        # cast refuses pipes and process substitution for --password-file (it requires a regular file), so the
        # password goes into an anonymous in-memory file (memfd): never on disk, never in argv or the environment.
        r = os.memfd_create("t2-keystore-password", 0)
        pw = self.password(role)
        os.write(r, pw)
        os.lseek(r, 0, os.SEEK_SET)
        args = ["cast", "mktx", "--keystore", str(ks), "--password-file", f"/dev/fd/{r}", "--chain", str(cid),
                "--nonce", str(tx.nonce), "--gas-limit", str(tx.gas), "--gas-price", str(max_fee),
                "--priority-gas-price", str(prio), "--value", str(tx.value)]
        args += ["--create", tx.data] if tx.to is None else [tx.to, tx.data]
        try:
            proc = subprocess.Popen(args, pass_fds=(r,), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env={k: v for k, v in os.environ.items() if not k.startswith(("ETH_", "CAST_"))})
            out, err = proc.communicate(timeout=120)
        finally:
            os.close(r)
            del pw
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


def send_plan(led: Ledger, lim: dict, binding: dict, step: str, cid: int, role: str, plan: list[PlannedTx],
              chain: EvmChain, signer: Signer, dispatched_topic: str, out: Callable[[str], None] = print,
              before_publish: Callable[[dict], None] | None = None) -> None:
    addr = binding["roles"][role].lower()
    if chain.chain_id() != cid:
        refuse(f"RPC for chain {cid} reports chain id {chain.chain_id()}")
    kinds = [classify(step, tx, binding, cid) for tx in plan]  # every tx classified before anything is signed
    for tx in plan:
        if tx.frm != addr:
            refuse(f"step {step}: planned broadcaster {tx.frm} is not the single unlocked role {role} ({addr})")
    for tx, kind in zip(plan, kinds):
        latest, pending = chain.nonce(addr), chain.nonce(addr, "pending")
        if latest != pending or tx.nonce != latest or led.mined_count(cid, addr) != latest:
            refuse(f"{role} nonce: plan {tx.nonce}, latest {latest}, pending {pending}, ledger "
                   f"{led.mined_count(cid, addr)}: nonce ambiguity, stop")
        base_fee, prio0 = chain.base_fee(), chain.priority_fee()
        max_fee, prio, cost = precheck(led, lim, cid, role, kind, tx, base_fee, prio0)
        raw = signer.sign(role, cid, tx, max_fee, prio)
        d = decode_signed(raw)
        verify_signed(d, cid, tx, max_fee, prio)
        rec = led.append({"type": "reserve", "chain": cid, "role": role, "from": addr, "kind": kind, "step": step,
                          "nonce": tx.nonce, "gas": tx.gas, "max_fee": max_fee, "priority": prio,
                          "value": str(tx.value), "max_cost": str(cost), "hash": d["hash"].lower(), "raw": raw,
                          "to": tx.to, "input_sha256": sha256_hex(bytes.fromhex(tx.data[2:]))})
        if before_publish:
            before_publish(rec)
        try:
            h = chain.publish(raw)
        except Exception as e:  # noqa: BLE001
            refuse(f"publish of {d['hash']} failed ({e}); it stays reserved until `reconcile`")
        if h.lower() != d["hash"].lower():
            refuse(f"node returned hash {h} for signed {d['hash']}")
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


class StarknetRpc:
    def __init__(self, url: str):
        self.rpc = Rpc(url)

    def nonce(self, a: str) -> int:
        try:
            return int(self.rpc.call("starknet_getNonce", ["latest", a]), 16)
        except RuntimeError as e:
            if "20" in str(e) or "not found" in str(e).lower():
                return 0
            raise

    def receipt(self, h: str) -> dict | None:
        try:
            return self.rpc.call("starknet_getTransactionReceipt", [h])
        except RuntimeError:
            return None

    def events(self, address: str, frm: int, chunk_token: str | None = None) -> dict:
        f = {"address": address, "from_block": {"block_number": frm}, "to_block": "latest", "chunk_size": 1000,
             "keys": []}
        if chunk_token:
            f["continuation_token"] = chunk_token
        return self.rpc.call("starknet_getEvents", [f])

    def class_hash_at(self, a: str) -> int:
        return int(self.rpc.call("starknet_getClassHashAt", ["latest", a]), 16)


def watch_starknet(led: Ledger, binding: dict, sn: StarknetRpc) -> None:
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
def sn_precheck(led: Ledger, lim: dict, kind: str, estimate_fri: int) -> int:
    sn = lim["starknet"]
    kd = sn["kinds"].get(kind)
    if kd is None:
        refuse(f"Starknet kind {kind} is not in the approved schedule")
    cap = int(kd["max_fee_fri"])
    if estimate_fri > cap:
        refuse(f"Starknet {kind}: fresh fee estimate {estimate_fri} above the per-tx maximum {cap}: stop and revise")
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


def sn_reconcile(led: Ledger, sn: StarknetRpc, account: str) -> None:
    for a in led.open_reserves(STARKNET_SEPOLIA):
        h = led.tx_hash(a)
        rc = sn.receipt(h) if h else None
        if rc and rc.get("finality_status") in ("ACCEPTED_ON_L2", "ACCEPTED_ON_L1"):
            led.append({"type": "outcome", "ref": a["seq"], "chain": STARKNET_SEPOLIA,
                        "status": 1 if rc.get("execution_status") == "SUCCEEDED" else 0,
                        "cost": str(int(rc["actual_fee"]["amount"], 16)), "block": rc.get("block_number", 0)})
    n = sn.nonce(account)
    mined = sum(1 for a in led.attempts(STARKNET_SEPOLIA)
                if (o := led.outcome(a["seq"])) is not None and o["type"] == "outcome")
    if n != mined:
        refuse(f"Starknet account nonce {n} != ledger mined {mined}: unknown or unreconciled transaction: stop")


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
        signer = Signer(Path(os.environ["T2_KEYSTORE_DIR"]), os.environ.get("T2_OP_VAULT", ""))
        send_plan(led, lim, scope.binding, a.step, cid, a.role, plan, chains[cid], signer, topics["Dispatched"],
                  before_publish=_fault_hook)
        watch_evm(led, scope.binding, chains, None, topics)


def cmd_preflight(_: argparse.Namespace) -> None:
    """Before any simulation: scope, unknown outcomes and nonce/ledger agreement (read-only; reconcile repairs)."""
    scope, _lim, _appr, _env = authorize()
    with Ledger(ledger_path(scope.binding)) as led:
        if led.open_reserves():
            refuse("an earlier attempt has an unknown outcome; run `reconcile` first")
        chains = evm_chains()
        for cid, ch in chains.items():
            for role, addr in evm_roles(scope.binding).items():
                if ch.nonce(addr) != led.mined_count(cid, addr):
                    refuse(f"chain {cid} {role}: on-chain nonce != ledger (deleted ledger, manual transaction or "
                           "lost receipt): stop")


def _fault_hook(_rec: dict) -> None:
    """Crash injection for the local fail-closed tests: it can only abort (after the reservation is durable and
    before the signed bytes are published), never skip a check."""
    if os.environ.get("T2_FAULT") == "after-reserve":
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


def cmd_sn(a: argparse.Namespace) -> None:
    """Starknet send: dry-run estimate -> per-tx and aggregate checks -> reserve -> sncast with --max-fee/--nonce."""
    scope, lim, _appr, _env = authorize()
    sn = StarknetRpc(os.environ["STARKNET_SEPOLIA_RPC_URL"])
    account = scope.binding["roles"]["starknet_account"]
    args = a.sncast
    if args and args[0] == "--":
        args = args[1:]
    if sn.rpc.call("starknet_chainId", []) != SN_CHAIN_ID_SEPOLIA:
        refuse("STARKNET_SEPOLIA_RPC_URL is not Starknet Sepolia")
    sn_validate(a.kind, args, scope.binding, os.environ["STARKNET_SEPOLIA_RPC_URL"])
    with Ledger(ledger_path(scope.binding)) as led:
        sn_reconcile(led, sn, account)
        watch_starknet(led, scope.binding, sn)
        nonce = sn.nonce(account)
        est = sncast_run(args + ["--dry-run"], json_out=True, kind=a.kind)
        fee = int(_find_fee(est))
        cap = sn_precheck(led, lim, a.kind, fee)
        rec = led.append({"type": "reserve", "chain": STARKNET_SEPOLIA, "role": "starknet", "from": account,
                          "kind": a.kind, "step": a.kind, "nonce": nonce, "value": "0", "max_cost": str(cap),
                          "hash": "", "argv_sha256": sha256_hex(" ".join(args).encode())})
        _fault_hook(rec)
        signer_opts = ["--max-fee", str(cap)] + ([] if a.kind == "account-deploy" else ["--nonce", str(nonce)])
        res = sncast_run(args + signer_opts, json_out=True, kind=a.kind)
        h = _find_hash(res)
        led.append({"type": "sn-sent", "ref": rec["seq"], "hash": h})
        for _ in range(450):
            rc = sn.receipt(h)
            if rc and rc.get("finality_status") in ("ACCEPTED_ON_L2", "ACCEPTED_ON_L1"):
                led.append({"type": "outcome", "ref": rec["seq"], "chain": STARKNET_SEPOLIA,
                            "status": 1 if rc.get("execution_status") == "SUCCEEDED" else 0,
                            "cost": str(int(rc["actual_fee"]["amount"], 16)), "block": rc.get("block_number", 0)})
                if rc.get("execution_status") != "SUCCEEDED":
                    refuse(f"Starknet {a.kind} {h} reverted: stop")
                if a.kind in SN_KIND_CONTRACT:
                    print("\n".join(sn_check_deployment(sn, scope.binding, SN_KIND_CONTRACT[a.kind])))
                print(f"Starknet {a.kind} {h} accepted, fee {int(rc['actual_fee']['amount'], 16)} fri (cap {cap})")
                return
            time.sleep(2)
        refuse(f"Starknet {a.kind} {h}: no receipt; stays reserved at {cap}")


def cmd_sn_check(_: argparse.Namespace) -> None:
    scope = compute_scope()
    check_binding(scope.binding, load_limits())
    sn = StarknetRpc(os.environ["STARKNET_SEPOLIA_RPC_URL"])
    if sn.rpc.call("starknet_chainId", []) != SN_CHAIN_ID_SEPOLIA:
        refuse("STARKNET_SEPOLIA_RPC_URL is not Starknet Sepolia")
    print("\n".join(sn_check_deployment(sn, scope.binding)))


def sncast_run(args: list[str], json_out: bool, kind: str = "") -> Any:
    ks = Path(os.environ["T2_KEYSTORE_DIR"])
    pw = subprocess.run(["op", "read", f"op://{os.environ['T2_OP_VAULT']}/t2-starknet/password"], check=True,
                        capture_output=True, text=True).stdout.rstrip("\n")
    env = {**os.environ, "KEYSTORE_PASSWORD": pw}  # sncast reads only this variable (CSO L-f: testnet keys only)
    cmd = ["sncast", "--keystore", str(ks / "t2-starknet.json"), "--account", str(ks / "t2-starknet.account.json")]
    if json_out:
        cmd.append("--json")
    cwd = repo_root() / SN_CONTRACTS[kind.split("-", 1)[1]][1] if kind in SN_DECLARE_NAME else None
    p = subprocess.run(cmd + args, capture_output=True, text=True, env=env, cwd=cwd)
    del pw, env
    if p.returncode != 0:
        refuse(f"sncast failed: {p.stderr[-400:]}")
    lines = [l for l in p.stdout.splitlines() if l.strip().startswith("{")]
    return [json.loads(l) for l in lines]


def _find(objs: Any, keys: tuple[str, ...]) -> Any:
    for o in objs:
        for k in keys:
            if isinstance(o, dict) and k in o:
                return o[k]
    refuse(f"sncast output lacks {keys}")


def _find_fee(objs: Any) -> int:
    v = _find(objs, ("overall_fee", "fee"))
    return int(v, 16) if isinstance(v, str) and v.startswith("0x") else int(v)


def _find_hash(objs: Any) -> str:
    return str(_find(objs, ("transaction_hash",)))


# Starknet `selector!("send_message_to_l1")` = starknet_keccak (== T2Config.SEND_MESSAGE_TO_L1_SELECTOR).
SN_CHAIN_ID_SEPOLIA = "0x534e5f5345504f4c4941"
SN_SIGNER_OPTS = ("--max-fee", "-m", "--nonce", "-n", "--l1-gas", "--l1-gas-price", "--l2-gas", "--l2-gas-price",
                  "--l1-data-gas", "--l1-data-gas-price", "--tip", "--estimate-tip", "--account", "--keystore",
                  "--accounts-file", "--network", "--wait")
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
            refuse(f"Starknet {c} {s[c]} class hash 0x{h:064x} != pinned {SN_CLASSES[c]}")
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
        "starknet": {"account": acct, "token": token, "staker": staker, "governor": governor,
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
