#!/usr/bin/env python3
"""EKU-1261 unit, negative and property tests of t2_guard.py and t2_budget.py (local only: no RPC, no key, no op).

Run: python3 l1_proxy/script/t2/test/test_t2_guard.py -v
"""

from __future__ import annotations

import copy
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
T2 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(T2))
import t2_budget  # noqa: E402
import t2_guard as g  # noqa: E402

LIM = json.loads((T2 / "t2-limits.json").read_text())
A = {k: "0x" + f"{i + 1:02x}" * 20 for i, k in enumerate(
    ["deployer", "bootstrap", "payer", "sa", "sb", "sc"])}
SN_ACCT = "0x0" + "ab" * 31


def binding() -> dict:
    p = {"proxy": "0x" + "10" * 20, "sender": "0x" + "11" * 20, "targets_97": ["0x" + "20" * 20, "0x" + "21" * 20],
         "safe_97": "0x" + "30" * 20, "executor_97": "0x" + "31" * 20,
         "targets_10143": ["0x" + f"4{i}" * 20 for i in range(4)], "safe_10143": "0x" + "30" * 20,
         "executor_10143": "0x" + "51" * 20}
    caps = {int(c): v["role_cap_wei"] for c, v in LIM["evm"].items()}
    roles = {"deployer": A["deployer"], "bootstrap": A["bootstrap"], "payer": A["payer"],
             "safe_owners": [A["sa"], A["sb"], A["sc"]], "starknet_account": SN_ACCT}
    return {
        "schema": "ekubo-t2-binding-v1", "status": "BOUND", "roles": roles, "safe_salt": "1232",
        "starknet": {"governor": "0x0123", "token": "0x1", "staker": "0x2", "stake_amount": LIM["starknet"]["stake_amount"]},
        "predicted": p, "limits": {"ccip_fee_max_wei": LIM["ccip"]["fee_max_wei"]},
        "funding_recipients": [{"chain": f"eip155:{c}", "role": r, "address": roles[r], "max": v}
                               for c, rc in caps.items() for r, v in rc.items()]
        + [{"chain": "starknet:SN_SEPOLIA", "role": "starknet", "address": SN_ACCT,
            "max": LIM["starknet"]["balance_cap_fri"]}],
        "faucet_sources": [],
    }


class LedgerCase(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "ledger-test.jsonl"
        self.led = g.Ledger(self.path).__enter__()

    def tearDown(self) -> None:
        self.led.__exit__()
        self.dir.cleanup()

    def reserve(self, cid, role, kind, gas, value=0, status=1, cost=None, open_=False, n=None):
        nonce = n if n is not None else self.led.mined_count(cid, A[role])
        r = self.led.append({"type": "reserve", "chain": cid, "role": role, "from": A[role], "kind": kind,
                             "nonce": nonce, "gas": gas, "max_fee": int(LIM["evm"][str(cid)]["gas_price_ceiling_wei"]),
                             "value": str(value), "max_cost": str(gas * int(LIM["evm"][str(cid)]["gas_price_ceiling_wei"]) + value),
                             "hash": "0x" + os.urandom(32).hex(), "raw": "0x"})
        if not open_:
            self.led.append({"type": "outcome", "ref": r["seq"], "chain": cid, "status": status, "block": 1,
                             "cost": str(cost if cost is not None else r["max_cost"]),
                             "dispatched": ["0x" + os.urandom(32).hex()] if kind == "dispatch" and status == 1 else []})
        return r


def tx(frm="payer", to=None, gas=100_000, value=0, data="0x", nonce=0):
    return g.PlannedTx(A[frm], to, value, data, nonce, gas)


class PrecheckTest(LedgerCase):
    def test_base_fee_above_ceiling_refused(self):
        with self.assertRaisesRegex(g.Refused, "above the gas-price ceiling"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "dispatch", tx(gas=300_000), 21 * g.GWEI, 0)

    def test_gas_above_kind_max_refused(self):
        mx = LIM["evm"]["11155111"]["kinds"]["dispatch"]["gas_max"]
        with self.assertRaisesRegex(g.Refused, "per-transaction maximum"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "dispatch", tx(gas=mx + 1), g.GWEI, 0)

    def test_value_only_on_dispatch_and_capped(self):
        with self.assertRaisesRegex(g.Refused, "value"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "l1-execute", tx(value=1), g.GWEI, 0)
        with self.assertRaisesRegex(g.Refused, "value"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "dispatch", tx(value=2 * 10**15 + 1), g.GWEI, 0)

    def test_kind_role_binding(self):
        with self.assertRaisesRegex(g.Refused, "not allowed for role"):
            g.precheck(self.led, LIM, g.SEPOLIA, "bootstrap", "dispatch", tx(frm="bootstrap"), g.GWEI, 0)

    def test_attempts_count_failed_ones(self):
        k = LIM["evm"]["11155111"]["kinds"]["l1-execute"]
        for _ in range(k["attempts_max"]):
            self.reserve(g.SEPOLIA, "payer", "l1-execute", 100_000, status=0, cost=1)
        with self.assertRaisesRegex(g.Refused, "failed, reverted and replaced attempts count"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "l1-execute", tx(), g.GWEI, 0)

    def test_open_reservation_blocks_next_attempt(self):
        self.reserve(g.SEPOLIA, "payer", "l1-execute", 100_000, open_=True)
        with self.assertRaisesRegex(g.Refused, "unknown outcome"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "l1-execute", tx(), g.GWEI, 0)

    def test_open_reservation_counts_at_maximum(self):
        r = self.reserve(g.SEPOLIA, "payer", "dispatch", 500_000, value=10**15, open_=True)
        self.assertEqual(self.led.exposure(g.SEPOLIA, "payer"), int(r["max_cost"]))

    def test_role_cap(self):
        cap = int(LIM["evm"]["11155111"]["role_cap_wei"]["bootstrap"])
        self.reserve(g.SEPOLIA, "bootstrap", "ping-request", 1, cost=cap - 10**12)
        with self.assertRaisesRegex(g.Refused, "role bootstrap"):
            g.precheck(self.led, LIM, g.SEPOLIA, "bootstrap", "ping-request", tx(frm="bootstrap", gas=100_000), g.GWEI, 0)

    def test_chain_cap(self):
        lim = copy.deepcopy(LIM)
        lim["evm"]["97"]["chain_cap_wei"] = str(10**14)
        with self.assertRaisesRegex(g.Refused, "exceeds"):
            g.precheck(self.led, lim, g.BNB_TESTNET, "payer", "execute", tx(gas=300_000), g.GWEI, 0)

    def test_ccip_message_cap_and_fees(self):
        for _ in range(9):
            self.reserve(g.SEPOLIA, "payer", "dispatch", 1, value=10**12, cost=10**12)
        with self.assertRaisesRegex(g.Refused, "successful-message cap"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "dispatch", tx(value=10**12), g.GWEI, 0)

    def test_failed_dispatch_counts_attempt_not_message(self):
        self.reserve(g.SEPOLIA, "payer", "dispatch", 1, value=10**15, status=0, cost=1)
        self.assertEqual(self.led.ccip(), (0, 0))
        self.assertEqual(self.led.kind_count(g.SEPOLIA, "dispatch"), 1)

    def test_signed_max_fee_is_ceiling_and_cost_is_full_limit(self):
        mf, prio, cost = g.precheck(self.led, LIM, g.MONAD_TESTNET, "payer", "execute", tx(gas=250_000),
                                    150 * g.GWEI, 80 * g.GWEI)
        self.assertEqual(mf, 200 * g.GWEI)
        self.assertEqual(prio, 50 * g.GWEI)
        self.assertEqual(cost, 250_000 * 200 * g.GWEI)


class PropertyTest(LedgerCase):
    def test_random_sequences_never_exceed_caps(self):
        rng = random.Random(1261)
        for cid in g.EVM_CHAINS:
            c = LIM["evm"][str(cid)]
            kinds = list(c["kinds"].items())
            for _ in range(400):
                k, kd = rng.choice(kinds)
                gas = rng.randint(21_000, int(kd["gas_max"]) + 50_000)
                value = rng.choice([0, rng.randint(1, 3 * 10**15)]) if k == "dispatch" else 0
                bf = rng.randint(0, int(c["gas_price_ceiling_wei"]) * 3 // 2)
                t = g.PlannedTx(A[kd["role"]], None, value, "0x", self.led.mined_count(cid, A[kd["role"]]), gas)
                try:
                    _, _, cost = g.precheck(self.led, LIM, cid, kd["role"], k, t, bf, 0)
                except g.Refused:
                    continue
                r = self.led.append({"type": "reserve", "chain": cid, "role": kd["role"], "from": A[kd["role"]],
                                     "kind": k, "nonce": t.nonce, "gas": gas, "max_fee": 0, "value": str(value),
                                     "max_cost": str(cost), "hash": "0x" + os.urandom(32).hex(), "raw": "0x"})
                if rng.random() < 0.97:  # otherwise the outcome stays unknown (reserved at max)
                    st = 1 if rng.random() < 0.8 else 0
                    actual = rng.randint(0, gas) * rng.randint(0, int(c["gas_price_ceiling_wei"])) + (value if st else 0)
                    self.led.append({"type": "outcome", "ref": r["seq"], "chain": cid, "status": st, "block": 1,
                                     "cost": str(actual), "dispatched": ["0x01"] if k == "dispatch" and st else []})
                for role, cap in c["role_cap_wei"].items():
                    self.assertLessEqual(self.led.exposure(cid, role), int(cap))
                self.assertLessEqual(self.led.exposure(cid), int(c["chain_cap_wei"]))
                self.assertLessEqual(len(self.led.attempts(cid)), c["attempts_max"])
                for kk, kkd in c["kinds"].items():
                    self.assertLessEqual(self.led.kind_count(cid, kk), kkd["attempts_max"])
            msgs, fees = self.led.ccip()
            self.assertLessEqual(msgs, 9)
            self.assertLessEqual(fees, 18 * 10**15)


class LedgerIntegrityTest(unittest.TestCase):
    def test_tamper_torn_and_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "ledger-x.jsonl"
            with g.Ledger(p) as led:
                led.append({"type": "reserve", "chain": 97, "role": "payer", "from": A["payer"], "kind": "execute",
                            "nonce": 0, "max_cost": "5", "value": "0", "hash": "0x1"})
                led.append({"type": "outcome", "ref": 0, "chain": 97, "status": 1, "cost": "5", "block": 1})
                with self.assertRaisesRegex(g.Refused, "locked by another"):
                    g.Ledger(p).__enter__()
            lines = p.read_text().splitlines()
            p.write_text(lines[0].replace('"5"', '"4"') + "\n" + lines[1] + "\n")
            with self.assertRaisesRegex(g.Refused, "hash chain"):
                g.Ledger(p).__enter__()
            p.write_text("\n".join(lines) + "\n")
            with g.Ledger(p) as led:
                self.assertEqual(led.exposure(97), 5)
            p.write_text("\n".join(lines))  # no trailing newline: torn write
            with self.assertRaisesRegex(g.Refused, "torn"):
                g.Ledger(p).__enter__()


class FakeChain:
    def __init__(self, cid):
        self.cid, self.nonces, self.receipts, self.published = cid, {}, {}, []

    def chain_id(self):
        return self.cid

    def nonce(self, a, tag="latest"):
        return self.nonces.get(a.lower(), 0)

    def receipt(self, h):
        return self.receipts.get(h)

    def publish(self, raw):
        self.published.append(raw)
        return "0x"


class ReconcileTest(LedgerCase):
    def test_nonce_ahead_of_ledger_refused(self):
        ch = FakeChain(97)
        ch.nonces[A["payer"]] = 1
        with self.assertRaisesRegex(g.Refused, "deleted ledger, manual transaction"):
            g.reconcile_evm(self.led, {97: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)

    def test_unknown_tx_consumed_reserved_nonce(self):
        r = self.reserve(97, "payer", "execute", 100_000, open_=True)
        ch = FakeChain(97)
        ch.nonces[A["payer"]] = 1
        with self.assertRaisesRegex(g.Refused, "NOT in the ledger"):
            g.reconcile_evm(self.led, {97: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)
        self.assertIsNone(self.led.outcome(r["seq"]))

    def test_receipt_reconciles_and_monad_charges_limit(self):
        r = self.reserve(g.MONAD_TESTNET, "payer", "execute", 300_000, open_=True)
        ch = FakeChain(g.MONAD_TESTNET)
        ch.nonces[A["payer"]] = 1
        ch.receipts[r["hash"]] = {"status": "0x1", "gasUsed": hex(100_000), "effectiveGasPrice": hex(100 * g.GWEI),
                                  "from": A["payer"], "transactionHash": r["hash"], "blockNumber": "0x5", "logs": []}
        g.reconcile_evm(self.led, {g.MONAD_TESTNET: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)
        self.assertEqual(int(self.led.outcome(r["seq"])["cost"]), 300_000 * 100 * g.GWEI)


class SignedFieldTest(unittest.TestCase):
    def test_every_field_is_compared(self):
        t = g.PlannedTx(A["payer"], "0x" + "aa" * 20, 7, "0x1234", 3, 90_000)
        base = {"signer": A["payer"], "chainId": hex(97), "nonce": "0x3", "gas": hex(90_000), "maxFeePerGas": hex(5),
                "maxPriorityFeePerGas": hex(1), "to": "0x" + "aa" * 20, "value": "0x7", "input": "0x1234",
                "type": "0x2", "accessList": []}
        g.verify_signed(base, 97, t, 5, 1)
        for k, bad in [("signer", A["bootstrap"]), ("chainId", hex(56)), ("nonce", "0x4"), ("gas", hex(90_001)),
                       ("maxFeePerGas", hex(6)), ("maxPriorityFeePerGas", hex(2)), ("to", "0x" + "bb" * 20),
                       ("value", "0x8"), ("input", "0x1235"), ("type", "0x0")]:
            d = dict(base, **{k: bad})
            with self.assertRaisesRegex(g.Refused, f"field {k}"):
                g.verify_signed(d, 97, t, 5, 1)
        with self.assertRaisesRegex(g.Refused, "access list"):
            g.verify_signed(dict(base, accessList=[{"address": "0x00", "storageKeys": []}]), 97, t, 5, 1)

    def test_real_cast_signature_round_trip(self):
        key = "0x" + "11" * 32
        addr = subprocess.run(["cast", "wallet", "address", key], check=True, capture_output=True,
                              text=True).stdout.strip().lower()
        t = g.PlannedTx(addr, "0x" + "aa" * 20, 0, "0xdeadbeef", 2, 50_000)
        raw = subprocess.run(["cast", "mktx", "--private-key", key, "--chain", "97", "--nonce", "2", "--gas-limit",
                              "50000", "--gas-price", "3000000000", "--priority-gas-price", "1", t.to, t.data],
                             check=True, capture_output=True, text=True).stdout.strip()
        g.verify_signed(g.decode_signed(raw), 97, t, 3_000_000_000, 1)
        with self.assertRaises(g.Refused):
            g.verify_signed(g.decode_signed(raw), 97, t, 3_000_000_000, 2)


class ClassifyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        g._init_selectors()

    def test_allowed_and_refused(self):
        b = binding()
        disp = g.PlannedTx(A["payer"], b["predicted"]["sender"], 1, g.SEL["dispatch"] + "00", 0, 1)
        self.assertEqual(g.classify("dispatch", disp, b, g.SEPOLIA), "dispatch")
        with self.assertRaisesRegex(g.Refused, "not an allowed"):
            g.classify("dispatch", g.PlannedTx(A["payer"], "0x" + "99" * 20, 0, g.SEL["dispatch"], 0, 1), b, g.SEPOLIA)
        with self.assertRaisesRegex(g.Refused, "not an allowed"):
            g.classify("ping-request", disp, b, g.SEPOLIA)
        self.assertEqual(g.classify("dest", g.PlannedTx(A["deployer"], None, 0, "0x60", 1, 1), b, 97), "deploy-target")
        self.assertEqual(g.classify("dest", g.PlannedTx(A["deployer"], None, 0, "0x60", 3, 1), b, 97), "deploy-executor")
        with self.assertRaisesRegex(g.Refused, "not an allowed"):
            g.classify("dest", g.PlannedTx(A["deployer"], None, 0, "0x60", 2, 1), b, 97)
        with self.assertRaisesRegex(g.Refused, "unknown signing step"):
            g.classify("sweep", disp, b, g.SEPOLIA)


class BindingTest(unittest.TestCase):
    def test_valid(self):
        g.check_binding(binding(), LIM)

    def refused(self, mutate, pat):
        b = binding()
        mutate(b)
        with self.assertRaisesRegex(g.Refused, pat):
            g.check_binding(b, LIM)

    def test_refusals(self):
        self.refused(lambda b: b.update(status="UNBOUND"), "not BOUND")
        self.refused(lambda b: b["roles"].update(payer=A["deployer"]), "pairwise distinct")
        self.refused(lambda b: b["roles"].update(payer=A["sa"]), "pairwise distinct")
        self.refused(lambda b: b["roles"].update(payer="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"), "public dev key")
        self.refused(lambda b: b["roles"].update(payer=g.COMPANY_KEY), "company key")
        self.refused(lambda b: b["starknet"].update(governor=hex(g.PRODUCTION_L2_GOVERNOR)), "Governor")
        self.refused(lambda b: b["limits"].update(ccip_fee_max_wei="3000000000000000"), "ccip_fee_max_wei")
        self.refused(lambda b: b["funding_recipients"].append(
            {"chain": "eip155:97", "role": "safe-signer-a", "address": A["sa"], "max": "1"}), "never funded")
        self.refused(lambda b: b["funding_recipients"][0].update(max=str(10**19)), "above the role cap")
        self.refused(lambda b: b["funding_recipients"][0].update(address=A["sa"]), "address != bound role")
        self.refused(lambda b: b["funding_recipients"].pop(), "exactly the funded roles")
        self.refused(lambda b: b["funding_recipients"][0].update(chain="eip155:1"), "not a funded role")


class LimitsTest(unittest.TestCase):
    def test_committed_limits_match_schedule(self):
        self.assertEqual(subprocess.run([sys.executable, str(T2 / "t2_budget.py"), "--check"]).returncode, 0)
        rows, errors = t2_budget.worst_case()
        self.assertEqual(errors, [])

    def test_raised_limits_refused(self):
        cases = [
            (lambda l: l["evm"]["11155111"].update(chain_cap_wei=str(26 * 10**16)), "chain cap"),
            (lambda l: l["evm"]["97"].update(gas_price_ceiling_wei=str(4 * 10**9)), "gas-price ceiling"),
            (lambda l: l["evm"]["10143"]["role_cap_wei"].update(payer=str(7 * 10**17)), "payer cap"),
            (lambda l: l["ccip"].update(fee_max_wei=str(3 * 10**15)), "per-message"),
            (lambda l: l["ccip"].update(messages_max=10), "message count"),
            (lambda l: l["starknet"].update(fee_cap_fri=str(49 * 10**18)), "Starknet caps"),
            (lambda l: l["starknet"]["kinds"]["execute-p2b"].update(max_fee_fri=str(11 * 10**18)), "per-tx max"),
            (lambda l: l["evm"]["97"]["kinds"]["execute"].update(value_max_wei="1"), "may carry value"),
        ]
        orig = g.LIMITS
        try:
            for mutate, pat in cases:
                lim = copy.deepcopy(LIM)
                mutate(lim)
                with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                    json.dump(lim, f)
                g.LIMITS = Path(f.name)
                with self.assertRaisesRegex(g.Refused, pat):
                    g.load_limits()
                os.unlink(f.name)
        finally:
            g.LIMITS = orig


class StarknetBudgetTest(LedgerCase):
    def sn(self, kind, cost, status=1, open_=False):
        r = self.led.append({"type": "reserve", "chain": g.STARKNET_SEPOLIA, "role": "starknet", "from": SN_ACCT,
                             "kind": kind, "nonce": 0, "value": "0",
                             "max_cost": LIM["starknet"]["kinds"][kind]["max_fee_fri"], "hash": ""})
        if not open_:
            self.led.append({"type": "outcome", "ref": r["seq"], "chain": g.STARKNET_SEPOLIA, "status": status,
                             "cost": str(cost), "block": 1})

    def test_per_tx_estimate_above_max_refused(self):
        with self.assertRaisesRegex(g.Refused, "fresh fee estimate"):
            g.sn_precheck(self.led, LIM, "execute-p2b", 7 * 10**18 + 1)

    def test_unknown_kind_refused(self):
        with self.assertRaisesRegex(g.Refused, "approved schedule"):
            g.sn_precheck(self.led, LIM, "transfer-strk", 1)

    def test_retry_budget_and_aggregate(self):
        for k in ("execute-p1", "execute-p2a", "execute-p2b"):
            self.sn(k, 7 * 10**18, status=0)
        self.sn("execute-p1", 7 * 10**18, status=0)  # retry 1
        self.sn("execute-p2a", 7 * 10**18, status=0)  # retry 2
        with self.assertRaisesRegex(g.Refused, "attempt cap|retry budget|exceed"):
            g.sn_precheck(self.led, LIM, "execute-p2b", 10**18)

    def test_aggregate_48(self):
        for k in ("declare-governor", "declare-staker", "declare-token", "execute-p1", "execute-p2a", "execute-p2b"):
            self.sn(k, int(LIM["starknet"]["kinds"][k]["max_fee_fri"]))
        self.sn("account-deploy", 10**18)  # 39 STRK spent
        self.sn("propose", 10**17, open_=True)
        self.led.append({"type": "void", "ref": self.led.records[-1]["seq"], "chain": g.STARKNET_SEPOLIA, "reason": "t"})
        lim = copy.deepcopy(LIM)
        lim["starknet"]["fee_cap_fri"] = str(335 * 10**17)
        with self.assertRaisesRegex(g.Refused, "exceed"):
            g.sn_precheck(self.led, lim, "deploy-token", 10**17)


class ApprovalTest(unittest.TestCase):
    def setUp(self):
        self.scope = g.Scope("m" * 64, "b" * 64, "t" * 64, "d" * 64, {}, "", "head")
        self.dir = tempfile.TemporaryDirectory()
        self.orig = g.APPROVAL
        g.APPROVAL = Path(self.dir.name) / "a.json"

    def tearDown(self):
        g.APPROVAL = self.orig
        self.dir.cleanup()

    def write(self, **kw):
        a = {"schema": "ekubo-t2-approval-v1", "stage": "final-transactions", "scope_digest": "d" * 64,
             "manifest_sha256": "m" * 64, "binding_sha256": "b" * 64, "tooling_sha256": "t" * 64,
             "approved_by": "human", "approval_ref": "ref", "approved_at": "2026-10-10T00:00:00Z",
             "expires_at": "2026-10-20T00:00:00Z", **kw}
        g.APPROVAL.write_text(json.dumps(a))

    def test_checks(self):
        at = g.parse_ts("2026-10-11T00:00:00Z")
        self.write()
        g.check_approval(self.scope, at)
        for kw, pat in [({"stage": "key-preparation"}, "does not authorize"), ({"scope_digest": "e" * 64}, "scope_digest"),
                        ({"tooling_sha256": "x" * 64}, "tooling_sha256"), ({"expires_at": "2026-10-25T00:00:01Z"}, "14 days"),
                        ({"approved_by": ""}, "approved_by"), ({"schema": "v0"}, "schema")]:
            self.write(**kw)
            with self.assertRaisesRegex(g.Refused, pat):
                g.check_approval(self.scope, at)
        self.write()
        with self.assertRaisesRegex(g.Refused, "not valid now"):
            g.check_approval(self.scope, g.parse_ts("2026-10-21T00:00:00Z"))

    def test_overrides(self):
        g.refuse_overrides({"T2_PAYER": "0xa"}, {"T2_PAYER": "0xa"})
        g.refuse_overrides({"T2_PAYER": "0xa"}, {})
        with self.assertRaisesRegex(g.Refused, "no overrides"):
            g.refuse_overrides({"T2_PAYER": "0xa"}, {"T2_PAYER": "0xb"})


class ScopeDigestTest(unittest.TestCase):
    def test_any_byte_changes_digest_and_dirty_tree_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            t2 = root / "l1_proxy/script/t2"
            (t2 / "binding").mkdir(parents=True)
            (root / "src").mkdir()
            for p, c in [(t2 / "binding/t2-manifest.md", "m"), (t2 / "binding/t2-binding.json", "{}"),
                         (t2 / "t2-limits.json", "{}"), (t2 / "tool.sh", "a"), (root / "src/x.cairo", "x")]:
                p.write_text(c)
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"}
            for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "x"]):
                subprocess.run(["git", "-C", d, *cmd], check=True, env=env)
            orig = (g.MANIFEST, g.BINDING, g.LIMITS)
            g.MANIFEST, g.BINDING, g.LIMITS = (t2 / "binding/t2-manifest.md", t2 / "binding/t2-binding.json",
                                               t2 / "t2-limits.json")
            try:
                s1 = g.compute_scope(root)
                (root / "src/x.cairo").write_text("y")
                with self.assertRaisesRegex(g.Refused, "committed tree"):
                    g.compute_scope(root)
                subprocess.run(["git", "-C", d, "commit", "-qam", "y"], check=True, env=env)
                s2 = g.compute_scope(root)
                self.assertNotEqual(s1.tooling_sha256, s2.tooling_sha256)
                self.assertNotEqual(s1.digest, s2.digest)
                self.assertEqual(s1.binding_sha256, s2.binding_sha256)
                (t2 / "new.sh").write_text("untracked")
                with self.assertRaisesRegex(g.Refused, "committed tree"):
                    g.compute_scope(root)
            finally:
                g.MANIFEST, g.BINDING, g.LIMITS = orig


class StarknetArgvTest(unittest.TestCase):
    """T2-2/L-b: only the bound Starknet targets, functions, calldata and message destination can be signed."""
    U = "http://sn.invalid"

    def setUp(self):
        self.b = binding()
        self.b["starknet"].update({"token": "0x" + "a1" * 31, "staker": "0x" + "a2" * 31,
                                   "governor": "0x" + "a3" * 31})
        self.sel = g.send_message_selector()

    def call(self, to=None, sel=None, proxy=None, payload=(7, 8, 9)):
        to = int(self.b["starknet"]["governor"], 16) if to is None else to
        proxy = int(self.b["predicted"]["proxy"], 16) if proxy is None else proxy
        cd = [proxy, len(payload), *payload]
        return [to, self.sel if sel is None else sel, len(cd), *cd]

    def inv(self, kind, to, fn, cd):
        return g.sn_validate(kind, ["invoke", "--url", self.U, "--contract-address", to, "--function", fn,
                                    "--calldata", *[str(x) for x in cd]], self.b, self.U)

    def test_selector_matches_solidity_constant(self):
        self.assertEqual(self.sel, int(g.cast_out("keccak", "send_message_to_l1"), 16) & ((1 << 250) - 1))

    def test_propose_ok_and_mutations_refused(self):
        gov = self.b["starknet"]["governor"]
        self.inv("propose", gov, "propose", [1, *self.call()])
        self.inv("propose", gov, "propose", [2, *self.call(), *self.call(payload=(1,))])
        bad = [
            [1, *self.call(to=int(self.b["starknet"]["staker"], 16))],  # call on another contract
            [1, *self.call(sel=self.sel ^ 1)],                         # another function
            [1, *self.call(proxy=int("0x" + "99" * 20, 16))],          # message to an unbound L1 address
            [3, *self.call(), *self.call(), *self.call()],             # too many calls
            [1, *self.call(), 5],                                      # trailing felt
            [2, *self.call()],                                         # truncated
        ]
        for cd in bad:
            with self.assertRaises(g.Refused):
                self.inv("propose", gov, "propose", cd)
        with self.assertRaises(g.Refused):
            self.inv("propose", self.b["starknet"]["staker"], "propose", [1, *self.call()])

    def test_execute_vote_stake_shapes(self):
        s, gov = self.b["starknet"], self.b["starknet"]["governor"]
        self.inv("execute-p1", gov, "execute", [5, 1, *self.call()])
        self.inv("vote", gov, "vote", [5, 1])
        with self.assertRaises(g.Refused):
            self.inv("vote", gov, "vote", [5, 0])
        amt = int(s["stake_amount"])
        self.inv("approve", s["token"], "approve", [int(s["staker"], 16), amt % (1 << 128), amt >> 128])
        self.inv("stake", s["staker"], "stake_amount", [int(SN_ACCT, 16), amt])
        with self.assertRaises(g.Refused):
            self.inv("stake", s["staker"], "stake_amount", [int(SN_ACCT, 16), amt + 1])
        with self.assertRaises(g.Refused):
            self.inv("approve", s["token"], "transfer", [int(s["staker"], 16), amt % (1 << 128), amt >> 128])

    def test_signer_options_and_url_refused(self):
        gov = self.b["starknet"]["governor"]
        for extra in (["--max-fee", "1"], ["--nonce", "3"], ["--l2-gas", "9"], ["--account", "x"]):
            with self.assertRaisesRegex(g.Refused, "set by the guard only"):
                g.sn_validate("vote", ["invoke", "--url", self.U, "--contract-address", gov, "--function", "vote",
                                       *extra, "--calldata", "5", "1"], self.b, self.U)
        with self.assertRaisesRegex(g.Refused, "--url"):
            g.sn_validate("vote", ["invoke", "--url", "http://other", "--contract-address", gov, "--function",
                                   "vote", "--calldata", "5", "1"], self.b, self.U)

    def test_deploy_constructor_bound(self):
        s = self.b["starknet"]
        base = ["deploy", "--url", self.U, "--salt", g.SN_SALT, "--unique"]
        g.sn_validate("deploy-staker", base + ["--class-hash", g.SN_CLASSES["staker"], "--constructor-calldata",
                                               s["token"]], self.b, self.U)
        g.sn_validate("deploy-governor", base + ["--class-hash", g.SN_CLASSES["governor"], "--constructor-calldata",
                                                 s["staker"], *g.SN_GOVERNOR_CONFIG], self.b, self.U)
        for args in (
            base + ["--class-hash", g.SN_CLASSES["token"], "--constructor-calldata", s["token"]],  # wrong class
            base + ["--class-hash", g.SN_CLASSES["staker"], "--constructor-calldata",
                    "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"],      # faucet STRK token
        ):
            with self.assertRaises(g.Refused):
                g.sn_validate("deploy-staker", args, self.b, self.U)
        cfg = list(g.SN_GOVERNOR_CONFIG)
        cfg[3] = "1"  # quorum 1 wei
        with self.assertRaises(g.Refused):
            g.sn_validate("deploy-governor", base + ["--class-hash", g.SN_CLASSES["governor"],
                                                     "--constructor-calldata", s["staker"], *cfg], self.b, self.U)

    def test_unknown_kind_refused(self):
        with self.assertRaises(g.Refused):
            self.inv("transfer", self.b["starknet"]["token"], "transfer", [1, 2, 0])


if __name__ == "__main__":
    unittest.main()
