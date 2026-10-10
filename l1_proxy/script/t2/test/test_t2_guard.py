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
from unittest import mock

sys.dont_write_bytecode = True
T2 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(T2))
import t2_budget  # noqa: E402
import t2_guard as g  # noqa: E402

LIM = json.loads((T2 / "t2-limits.json").read_text())
A = {k: "0x" + f"{i + 1:02x}" * 20 for i, k in enumerate(
    ["deployer", "bootstrap", "payer", "sa", "sb", "sc"])}
SN_PUB, SN_CLASS, SN_SALT_A = "0x" + "5a" * 31, g.SN_OZ_ACCOUNT_CLASS, "0x" + "5c" * 8
# R2-D: the bound address is the DEPLOY_ACCOUNT address of the fixture identity (vectors: StarknetAddressDerivationTest)
SN_ACCT = hex(g.sn_contract_address(int(SN_CLASS, 16), int(SN_SALT_A, 16), [int(SN_PUB, 16)]))
EVM_KS = {r: ('{"crypto":{"cipher":"aes-128-ctr"},"id":"evm-%s-fixture","version":3}' % r).encode()
          for r in ("deployer", "bootstrap", "payer")}


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
        "starknet": {"governor": "0x0123", "token": "0x1", "staker": "0x2", "stake_amount": LIM["starknet"]["stake_amount"],
                     "account": SN_ACCT, "account_public_key": SN_PUB, "account_class_hash": SN_CLASS,
                     "account_salt": SN_SALT_A, "account_type": "open_zeppelin",
                     "keystore_sha256": g.sha256_hex(SN_KS)},
        "predicted": p, "limits": {"ccip_fee_max_wei": LIM["ccip"]["fee_max_wei"]},
        "funding_recipients": [{"chain": f"eip155:{c}", "role": r, "address": roles[r], "max": v}
                               for c, rc in caps.items() for r, v in rc.items()]
        + [{"chain": "starknet:SN_SEPOLIA", "role": "starknet", "address": SN_ACCT,
            "max": LIM["starknet"]["balance_cap_fri"]}],
        "faucet_sources": faucet_sources(),
        "op_vault": "t2-unit-test", "ledger_dir": "/nonexistent/t2-unit-test-ledger",
        "evm_keystore_sha256": {r: g.sha256_hex(v) for r, v in EVM_KS.items()},
    }


SN_KS = b'{"crypto":{"cipher":"aes-128-ctr"},"id":"unit-test-fixture","version":3}'


def faucet_sources() -> list[dict]:
    return [{"chain": c, "source": f"free-{c}", "url": "https://faucet.invalid/", "eligibility": "unit-test fixture",
             "eligibility_checked_at": "2026-10-10T00:00:00Z", "drip_max": "1", "login": "none", "region": "any",
             "operator": "named human (fixture)", "automated_allowed": False, "paid": False,
             "mainnet_prerequisite": False}
            for c in ("eip155:11155111", "eip155:97", "eip155:10143", "starknet:SN_SEPOLIA")]


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
        self.reserve(g.SEPOLIA, "bootstrap", "ping-request", 500_000, cost=cap - 10**12)
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
        self.refused(lambda b: b["funding_recipients"].pop(0), "exactly the funded roles")
        self.refused(lambda b: b["funding_recipients"].pop(), "no Starknet funding recipient")
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
        est = {"l1_gas_consumed": 1, "l1_gas_price": 1, "l2_gas_consumed": 7 * 10**18, "l2_gas_price": 1,
               "l1_data_gas_consumed": 1, "l1_data_gas_price": 1}
        with self.assertRaisesRegex(g.Refused, "fresh estimate"):
            g.sn_bounds(est, 7 * 10**18)
        b = g.sn_bounds(dict(est, l2_gas_consumed=10**18), 7 * 10**18)
        self.assertLessEqual(g.sn_liability(b), 7 * 10**18)

    def test_unknown_kind_refused(self):
        with self.assertRaisesRegex(g.Refused, "approved schedule"):
            g.sn_precheck(self.led, LIM, "transfer-strk")

    def test_retry_budget_and_aggregate(self):
        for k in ("execute-p1", "execute-p2a", "execute-p2b"):
            self.sn(k, 7 * 10**18, status=0)
        self.sn("execute-p1", 7 * 10**18, status=0)  # retry 1
        self.sn("execute-p2a", 7 * 10**18, status=0)  # retry 2
        with self.assertRaisesRegex(g.Refused, "attempt cap|retry budget|exceed"):
            g.sn_precheck(self.led, LIM, "execute-p2b")

    def test_aggregate_48(self):
        for k in ("declare-governor", "declare-staker", "declare-token", "execute-p1", "execute-p2a", "execute-p2b"):
            self.sn(k, int(LIM["starknet"]["kinds"][k]["max_fee_fri"]))
        self.sn("account-deploy", 10**18)  # 39 STRK spent
        self.sn("propose", 10**17, open_=True)
        self.led.append({"type": "void", "ref": self.led.records[-1]["seq"], "chain": g.STARKNET_SEPOLIA, "reason": "t"})
        lim = copy.deepcopy(LIM)
        lim["starknet"]["fee_cap_fri"] = str(335 * 10**17)
        with self.assertRaisesRegex(g.Refused, "exceed"):
            g.sn_precheck(self.led, lim, "deploy-token")


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


# ==================================================================================================== EKU-1268
# CFO R1/R2, CSO N-1..N-8. Local only: fake chains, fake signers/sncast runners, scratch ledgers; the optional sncast
# compatibility test uses a throwaway local keystore against a local fake JSON-RPC node (nothing leaves the machine).
import http.server  # noqa: E402
import shutil  # noqa: E402
import threading  # noqa: E402

TESTS = Path(__file__).resolve().parent


def raw_hash(raw: str) -> str:
    return "0x" + g.sha256_hex(raw.encode())


class EvmFake:
    """Chain fake for send_plan/reconcile: publish() mines immediately and returns the fake hash of the raw bytes."""

    def __init__(self, cid, sender, reported_chain_id=None, mine=True):
        self.cid, self.sender, self.reported = cid, sender.lower(), reported_chain_id or cid
        self.nonces, self.receipts, self.published, self.mine = {}, {}, [], mine

    def chain_id(self):
        return self.reported

    def nonce(self, a, tag="latest"):
        return self.nonces.get(a.lower(), 0)

    def base_fee(self):
        return g.GWEI

    def priority_fee(self):
        return 0

    def receipt(self, h):
        return self.receipts.get(h)

    def publish(self, raw):
        self.published.append(raw)
        h = raw_hash(raw)
        if self.mine:
            self.receipts[h] = {"status": "0x1", "gasUsed": hex(100_000), "effectiveGasPrice": hex(g.GWEI),
                                "from": self.sender, "transactionHash": h, "blockNumber": "0x9", "logs": []}
            self.nonces[self.sender] = self.nonces.get(self.sender, 0) + 1
        return h


class FakeSigner:
    """Key-free signer: returns opaque bytes and their 'decoded' fields. At call time it reads the ledger FROM DISK
    and records whether a durable, unlinked reservation for exactly this intent already exists (CFO R1)."""

    def __init__(self, ledger_path, signer_addr=None, crash=False):
        self.path, self.signer_addr, self.crash = Path(ledger_path), signer_addr, crash
        self.calls, self.decoded, self.disk_state = 0, {}, []

    def freeze(self, role):
        return b""

    def sign(self, role, cid, tx, max_fee, prio):
        self.calls += 1
        recs = [json.loads(line) for line in self.path.read_text().splitlines()]
        last = recs[-1]
        linked = any(r["type"] in ("signed", "void", "outcome") and r.get("ref") == last["seq"] for r in recs)
        self.disk_state.append((last["type"], last["chain"], last["role"], last["nonce"], last["hash"],
                                int(last["max_cost"]), linked))
        if self.crash:
            os._exit(97)  # simulated crash DURING signing
        raw = "0x" + os.urandom(40).hex()
        self.decoded[raw] = {"signer": self.signer_addr or tx.frm, "chainId": hex(cid), "nonce": hex(tx.nonce),
                             "gas": hex(tx.gas), "maxFeePerGas": hex(max_fee), "maxPriorityFeePerGas": hex(prio),
                             "to": tx.to, "value": hex(tx.value), "input": tx.data, "type": "0x2",
                             "accessList": [], "hash": raw_hash(raw)}
        return raw


def l1exec_tx(n=0):
    g._init_selectors()
    return g.PlannedTx(A["payer"], binding()["predicted"]["proxy"], 0, g.SEL["proxyExecute"] + "00" * 4, n, 200_000)


def run_send(led, chain, signer, plan=None, fault=g._no_fault, role="payer", step="l1exec"):
    g.send_plan(led, LIM, binding(), step, g.SEPOLIA, role, plan or [l1exec_tx(chain.nonce(A["payer"]))], chain,
                signer, "0xdd", out=lambda s: None, fault=fault, decode=lambda raw: signer.decoded[raw])


class PreSignReservationTest(LedgerCase):
    """CFO R1: reservation fsync'd before the signer runs; signed bytes linked afterwards; no sign-then-reserve."""

    def test_reservation_is_on_disk_before_the_signer_runs(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"]), FakeSigner(self.path)
        run_send(self.led, ch, s)
        self.assertEqual(s.calls, 1)
        typ, cid, role, nonce, h, max_cost, linked = s.disk_state[0]
        self.assertEqual((typ, cid, role, nonce, h, linked), ("reserve", g.SEPOLIA, "payer", 0, "", False))
        self.assertEqual(max_cost, 200_000 * 20 * g.GWEI)
        types = [r["type"] for r in self.led.records]
        self.assertEqual(types, ["reserve", "signed", "outcome"])
        res = self.led.records[0]
        self.assertEqual(res["attempt"], 1)
        self.assertEqual(res["intent_sha256"], g.sha256_hex(json.dumps(
            {k: res[k] for k in ("chain", "role", "from", "kind", "step", "nonce", "gas", "max_fee", "priority",
                                 "value", "to", "input_sha256")}, sort_keys=True).encode()))
        self.assertEqual(self.led.tx_hash(res), raw_hash(ch.published[0]))

    def test_in_process_signed_field_refusal_voids_but_counts_the_attempt(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"]), FakeSigner(self.path, signer_addr=A["bootstrap"])
        with self.assertRaisesRegex(g.Refused, "field signer"):
            run_send(self.led, ch, s)
        self.assertEqual(ch.published, [])
        self.assertEqual([r["type"] for r in self.led.records], ["reserve", "void"])
        self.assertIn("never published", self.led.records[1]["reason"])
        self.assertEqual(self.led.kind_count(g.SEPOLIA, "l1-execute"), 1)
        self.assertEqual(self.led.exposure(g.SEPOLIA), 0)
        run_send(self.led, ch, FakeSigner(self.path))  # the next attempt is allowed and counted as attempt 2
        self.assertEqual(self.led.attempts(g.SEPOLIA)[-1]["attempt"], 2)

    def test_signer_error_that_is_not_a_refusal_leaves_the_slot_unresolved(self):
        class Boom(FakeSigner):
            def sign(self, *a):
                super().sign(*a)
                raise subprocess.TimeoutExpired("cast mktx", 120)  # e.g. a hung signer: outcome unknown
        ch, s = EvmFake(g.SEPOLIA, A["payer"]), Boom(self.path)
        with self.assertRaises(subprocess.TimeoutExpired):
            run_send(self.led, ch, s)
        (a,) = self.led.open_reserves(g.SEPOLIA)
        self.assertEqual((self.led.link(a), ch.published), (None, []))
        with self.assertRaisesRegex(g.Refused, "permanent stop"):
            g.reconcile_evm(self.led, {g.SEPOLIA: ch}, {"payer": A["payer"]}, True, "0xdd", out=lambda s: None)

    def test_broadcaster_not_role_refused_before_any_signer_or_reservation(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"]), FakeSigner(self.path)
        g._init_selectors()
        tx = g.PlannedTx(A["deployer"], binding()["predicted"]["proxy"], 0, g.SEL["proxyExecute"], 0, 200_000)
        with self.assertRaisesRegex(g.Refused, "not the single unlocked role"):
            run_send(self.led, ch, s, plan=[tx])
        self.assertEqual((s.calls, self.led.records, ch.published), (0, [], []))

    def test_precheck_refusal_reaches_no_signer(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"]), FakeSigner(self.path)
        tx = l1exec_tx()
        tx.gas = 10**6  # above the kind maximum
        with self.assertRaisesRegex(g.Refused, "per-transaction maximum"):
            run_send(self.led, ch, s, plan=[tx])
        self.assertEqual((s.calls, self.led.records), (0, []))

    def test_wrong_chain_id_refused_before_any_signer(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"], reported_chain_id=1), FakeSigner(self.path)
        with self.assertRaisesRegex(g.Refused, "reports chain id 1"):
            run_send(self.led, ch, s)
        self.assertEqual((s.calls, self.led.records), (0, []))

    def test_linked_then_crash_republish_is_same_liability(self):
        ch, s = EvmFake(g.SEPOLIA, A["payer"], mine=False), FakeSigner(self.path)

        def boom(point, _rec):
            if point == "linked":
                raise KeyboardInterrupt  # in-process stand-in; the subprocess probe below uses a real exit
        with self.assertRaises(KeyboardInterrupt):
            run_send(self.led, ch, s, fault=boom)
        a = self.led.attempts(g.SEPOLIA)[0]
        self.assertEqual(self.led.open_reserves(g.SEPOLIA), [a])
        before = (len(self.led.attempts()), self.led.exposure(g.SEPOLIA))
        ch.mine = True
        g.reconcile_evm(self.led, {g.SEPOLIA: ch}, {"payer": A["payer"]}, True, "0xdd", out=lambda s: None)
        self.assertEqual(ch.published, [self.led.raw(a)])  # the identical linked bytes, once
        self.assertEqual(len(self.led.attempts()), before[0])  # no new slot
        self.assertLessEqual(self.led.exposure(g.SEPOLIA), before[1])


CHILD = r'''
import json, os, sys
sys.path[:0] = [sys.argv[1], sys.argv[2]]
sys.dont_write_bytecode = True
import t2_guard as g
import test_t2_guard as T
from pathlib import Path
mode, path = sys.argv[3], Path(sys.argv[4])
with g.Ledger(path) as led:
    if mode.startswith("evm-"):
        point = mode[4:]
        ch = T.EvmFake(g.SEPOLIA, T.A["payer"], mine=False)
        s = T.FakeSigner(path, crash=(point == "during-sign"))
        def fault(p, rec):
            if p == point:
                os._exit(97)
        T.run_send(led, ch, s, fault=fault)
    else:
        point = mode[3:]
        sn = T.FakeSn()
        r = T.FakeRunner(path, sn, crash_on_send=(point == "during-send"))
        def fault(p, rec):
            if p == point:
                os._exit(97)
        T.sn_vote(led, sn, r, fault=fault)
print("NO CRASH")
'''


def crash_child(mode: str, ledger: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-c", CHILD, str(T2), str(TESTS), mode, str(ledger)],
                          capture_output=True, text=True)


class CrashBoundaryTest(unittest.TestCase):
    """CFO R1 / N-2 with a REAL process exit (os._exit, no cleanup): the durable reservation survives and blocks."""

    def probe(self, mode):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        p = Path(d.name) / "ledger.jsonl"
        r = crash_child(mode, p)
        self.assertEqual(r.returncode, 97, r.stdout + r.stderr)
        return g.Ledger(p).__enter__(), p

    def test_evm_crash_during_signing_and_before_link(self):
        for point in ("during-sign", "signed"):
            with self.subTest(point=point):
                led, p = self.probe(f"evm-{point}")
                self.addCleanup(led.__exit__)
                (a,) = led.open_reserves(g.SEPOLIA)
                self.assertEqual((a["kind"], a["nonce"], led.tx_hash(a), led.link(a)), ("l1-execute", 0, "", None))
                self.assertEqual(led.exposure(g.SEPOLIA, "payer"), int(a["max_cost"]))
                s = FakeSigner(p)
                with self.assertRaisesRegex(g.Refused, "unknown outcome"):
                    run_send(led, EvmFake(g.SEPOLIA, A["payer"]), s)
                self.assertEqual(s.calls, 0)
                with self.assertRaisesRegex(g.Refused, r"no linked signed transaction.*permanent stop \(N-2\)"):
                    g.reconcile_evm(led, {g.SEPOLIA: EvmFake(g.SEPOLIA, A["payer"])}, {"payer": A["payer"]}, True,
                                    "0xdd", out=lambda s: None)
                self.assertEqual(led.open_reserves(g.SEPOLIA), [a])  # never released by an absent transaction

    def test_evm_crash_after_link_republishes_identical_bytes(self):
        led, p = self.probe("evm-linked")
        self.addCleanup(led.__exit__)
        (a,) = led.open_reserves(g.SEPOLIA)
        self.assertTrue(led.raw(a))
        ch = EvmFake(g.SEPOLIA, A["payer"])
        g.reconcile_evm(led, {g.SEPOLIA: ch}, {"payer": A["payer"]}, True, "0xdd", out=lambda s: None)
        self.assertEqual(ch.published, [led.raw(a)])
        self.assertEqual((led.open_reserves(), len(led.attempts())), ([], 1))

    def test_starknet_crash_after_reservation_and_after_send(self):
        for point in ("reserved", "bounded", "during-send", "signed"):
            with self.subTest(point=point):
                led, p = self.probe(f"sn-{point}")
                self.addCleanup(led.__exit__)
                (a,) = led.open_reserves(g.STARKNET_SEPOLIA)
                self.assertEqual((led.tx_hash(a), led.exposure(g.STARKNET_SEPOLIA)), ("", int(a["max_cost"])))
                sn, r = FakeSn(), FakeRunner(p, FakeSn())
                with self.assertRaisesRegex(g.Refused, r"no linked transaction hash.*permanent stop \(N-2\)"):
                    sn_vote(led, sn, r)
                self.assertEqual(r.calls, [])


class ConcurrencyTest(unittest.TestCase):
    def test_second_runner_refused_before_any_signer(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "ledger.jsonl"
            holder = subprocess.Popen([sys.executable, "-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); "
                                       "fcntl.flock(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)",
                                       str(p.with_suffix(".lock"))], stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                with self.assertRaisesRegex(g.Refused, "locked by another T2 runner"):
                    g.Ledger(p).__enter__()
            finally:
                holder.kill()
                holder.wait()


# ---------------------------------------------------------------- N-1: committed stop-condition tests (CSO probe)
WP = {"proxy": "0x" + "10" * 20, "sender": "0x" + "11" * 20, "targets_97": ["0x" + "20" * 20],
      "safe_97": "0x" + "30" * 20, "executor_97": "0x" + "31" * 20, "targets_10143": ["0x" + "40" * 20],
      "safe_10143": "0x" + "50" * 20, "executor_10143": "0x" + "51" * 20}
WB = {"predicted": WP, "roles": {"deployer": "0x" + "01" * 20, "bootstrap": "0x" + "02" * 20, "payer": "0x" + "03" * 20,
                                 "safe_owners": ["0x" + "0a" * 20, "0x" + "0b" * 20, "0x" + "0c" * 20],
                                 "starknet_account": "0x0" + "ab" * 31},
      "starknet": {"token": "0x111", "staker": "0x222", "governor": "0x333"}}
OURS, OTHER = "0x" + "aa" * 32, "0x" + "bb" * 32


class _WRpc:
    def call(self, m, p):
        return "0x60" if m == "eth_getCode" else None


class WatchChain:
    def __init__(self, cid, logs=(), nonces=None, proxy_nonce=0, reported=None):
        self.cid, self._logs, self.nonces, self.pn, self.rpc = cid, list(logs), nonces or {}, proxy_nonce, _WRpc()
        self.reported = reported or cid

    def chain_id(self):
        return self.reported

    def nonce(self, a, tag="latest"):
        return self.nonces.get(a.lower(), 0)

    def block_number(self):
        return 200

    def logs(self, addr, f, t):
        return [x for x in self._logs if x["address"].lower() == addr.lower() and f <= x["bn"] <= t]

    def call(self, to, data):
        return hex(self.pn)


def wlog(addr, topic0, t1, tx, bn=150):
    return {"address": addr, "topics": [topic0, t1], "transactionHash": tx, "bn": bn}


class StopConditionTest(unittest.TestCase):
    """CSO N-1: watch_evm / watch_starknet / sn_reconcile stop conditions (adopted from EKU-1262 cso_watch_test)."""

    @classmethod
    def setUpClass(cls):
        cls.top = {"Pinged": g._topic("Pinged(bytes32,bytes32,uint64)"),
                   "Queued": g._topic("Queued(bytes32,bytes32,uint64,uint64,uint64,bytes)"), "Dispatched": "0xdd"}
        g.SEL_CURRENT_NONCE[0] = g._topic("currentNonce()")[:10]

    def ledger(self, d, chain=97, mined_hash="0x" + "cc" * 32, dispatched=(OURS,), l1exec=0):
        L = g.Ledger(Path(d) / "l.jsonl").__enter__()
        self.addCleanup(L.__exit__)
        r = L.append({"type": "reserve", "chain": g.SEPOLIA, "role": "payer", "from": WB["roles"]["payer"],
                      "kind": "dispatch", "nonce": 0, "value": "0", "max_cost": "1", "hash": "0x" + "dd" * 32})
        L.append({"type": "outcome", "ref": r["seq"], "chain": g.SEPOLIA, "status": 1, "block": 100, "cost": "1",
                  "dispatched": list(dispatched)})
        for i in range(l1exec):
            r = L.append({"type": "reserve", "chain": g.SEPOLIA, "role": "payer", "from": WB["roles"]["payer"],
                          "kind": "l1-execute", "nonce": i + 1, "value": "0", "max_cost": "1", "hash": f"0x{i:064x}"})
            L.append({"type": "outcome", "ref": r["seq"], "chain": g.SEPOLIA, "status": 1, "block": 101, "cost": "1"})
        r = L.append({"type": "reserve", "chain": chain, "role": "deployer", "from": WB["roles"]["deployer"],
                      "kind": "x", "nonce": 0, "value": "0", "max_cost": "1", "hash": mined_hash})
        L.append({"type": "outcome", "ref": r["seq"], "chain": chain, "status": 1, "block": 100, "cost": "1"})
        return L

    def watch(self, chains, **kw):
        with tempfile.TemporaryDirectory() as d:
            g.watch_evm(self.ledger(d, **kw), WB, chains, None, self.top, out=lambda s: None)

    def test_clean_executor_event_for_our_payload(self):
        self.watch({97: WatchChain(97, [wlog(WP["executor_97"], self.top["Queued"], OURS, "0x" + "ee" * 32)])})
        self.watch({97: WatchChain(97, [wlog(WP["executor_97"], self.top["Pinged"], OURS, "0x" + "ee" * 32)])})

    def test_unknown_payload_queued_or_pinged_stops(self):
        for t in ("Queued", "Pinged"):
            with self.assertRaisesRegex(g.Refused, "UNKNOWN payload"):
                self.watch({97: WatchChain(97, [wlog(WP["executor_97"], self.top[t], OTHER, "0x" + "ee" * 32)])})

    def test_foreign_tx_log_stops(self):
        with self.assertRaisesRegex(g.Refused, "not in the ledger"):
            self.watch({g.SEPOLIA: WatchChain(g.SEPOLIA, [wlog(WP["sender"], "0x01", OTHER, "0x" + "ef" * 32)])},
                       chain=g.SEPOLIA)
        with self.assertRaisesRegex(g.Refused, "not in the ledger"):
            self.watch({97: WatchChain(97, [wlog(WP["safe_97"], "0x02", OTHER, "0x" + "ef" * 32)])})
        self.watch({97: WatchChain(97, [wlog(WP["safe_97"], "0x02", OTHER, "0x" + "cc" * 32)])})  # ledger tx: ok

    def test_safe_signer_nonce_stops(self):
        with self.assertRaisesRegex(g.Refused, "Safe signer"):
            self.watch({97: WatchChain(97, nonces={WB["roles"]["safe_owners"][1]: 1})})

    def test_proxy_nonce_consumed_stops_and_matching_passes(self):
        with self.assertRaisesRegex(g.Refused, "currentNonce"):
            self.watch({g.SEPOLIA: WatchChain(g.SEPOLIA, proxy_nonce=1)}, chain=g.SEPOLIA)
        self.watch({g.SEPOLIA: WatchChain(g.SEPOLIA, proxy_nonce=2)}, chain=g.SEPOLIA, l1exec=2)
        with self.assertRaisesRegex(g.Refused, "currentNonce"):
            self.watch({g.SEPOLIA: WatchChain(g.SEPOLIA, proxy_nonce=1)}, chain=g.SEPOLIA, l1exec=2)

    def test_watch_chain_id_on_every_chain(self):  # N-4
        with self.assertRaisesRegex(g.Refused, "reports chain id 56"):
            self.watch({97: WatchChain(97), 10143: WatchChain(10143, reported=56)})

    def test_starknet_foreign_event_stops_and_own_passes(self):
        for tx, ok in (("0x999", False), ("0x123", True)):
            sn = FakeSn()
            sn.ev = {"0x333": [{"transaction_hash": tx}]}
            with tempfile.TemporaryDirectory() as d:
                L = g.Ledger(Path(d) / "l.jsonl").__enter__()
                self.addCleanup(L.__exit__)
                r = L.append({"type": "reserve", "chain": g.STARKNET_SEPOLIA, "role": "starknet", "from": "0x1",
                              "kind": "vote", "nonce": 0, "value": "0", "max_cost": "1", "hash": ""})
                L.append({"type": "sn-sent", "ref": r["seq"], "hash": "0x123"})
                L.append({"type": "outcome", "ref": r["seq"], "chain": g.STARKNET_SEPOLIA, "status": 1, "cost": "1",
                          "block": 5})
                if ok:
                    g.watch_starknet(L, WB, sn)
                else:
                    with self.assertRaisesRegex(g.Refused, "not in the ledger"):
                        g.watch_starknet(L, WB, sn)

    def test_starknet_nonce_mismatch_and_wrong_chain_stop(self):
        with tempfile.TemporaryDirectory() as d:
            L = g.Ledger(Path(d) / "l.jsonl").__enter__()
            self.addCleanup(L.__exit__)
            sn = FakeSn()
            sn.nonce_v = 1
            with self.assertRaisesRegex(g.Refused, "nonce"):
                g.sn_reconcile(L, sn, "0x1")
            sn.nonce_v, sn.cid = 0, "0x534e5f4d41494e"
            with self.assertRaisesRegex(g.Refused, "not SN_SEPOLIA"):
                g.sn_reconcile(L, sn, "0x1")
            with self.assertRaisesRegex(g.Refused, "not SN_SEPOLIA"):
                g.watch_starknet(L, WB, sn)

    def test_reconcile_chain_id_on_every_chain(self):  # N-4
        with tempfile.TemporaryDirectory() as d:
            L = g.Ledger(Path(d) / "l.jsonl").__enter__()
            self.addCleanup(L.__exit__)
            chains = {g.SEPOLIA: EvmFake(g.SEPOLIA, A["payer"]), 97: EvmFake(97, A["payer"], reported_chain_id=56)}
            with self.assertRaisesRegex(g.Refused, "chain 97 reports chain id 56"):
                g.reconcile_evm(L, chains, {"payer": A["payer"]}, False, "0xdd", out=lambda s: None)


# ---------------------------------------------------------------- Starknet identity, sends and reconciliation (R2)
SN_GOV = "0x" + "a3" * 31
SN_FEE_EST = {"command": "invoke", "l1_gas_consumed": 16, "l1_gas_price": 10**9, "l2_gas_consumed": 10**6,
              "l2_gas_price": 10**10, "l1_data_gas_consumed": 128, "l1_data_gas_price": 10**9, "overall_fee": 0}
# Observed from the installed sncast 0.62.1 against a local fake node (EKU-1268 evidence): independent constants.
SNCAST_VOTE_SELECTOR = 0x132bdf85fc8aa10ac3c22f02317f8f53d4b4f52235ed1eabb3a4cbbe08b5c41
SNCAST_DEPLOY_SELECTOR = 0x1987cbd17808b9a23693d4de7e246a443cfe37e6e7fbaeabd7d7e6532b07c3d


def sn_binding():
    b = binding()
    b["starknet"].update({"token": "0x" + "a1" * 31, "staker": "0x" + "a2" * 31, "governor": SN_GOV})
    return b


class FakeSn:
    """Starknet RPC fake: chain id, nonce, class/public key of the account, stored txs/receipts and events."""

    def __init__(self):
        self.cid, self.nonce_v, self.pub = g.SN_CHAIN_ID_SEPOLIA, 0, SN_PUB
        self.classes = {int(SN_ACCT, 16): int(SN_CLASS, 16)}
        self.txs, self.rcs, self.ev = {}, {}, {}
        self.rpc = self

    def chain_id(self):
        return self.cid

    def nonce(self, a):
        return self.nonce_v

    def receipt(self, h):
        return self.rcs.get(h)

    def transaction(self, h):
        return self.txs.get(h)

    def events(self, addr, frm, tok=None):
        return {"events": self.ev.get(addr, [])}

    def class_hash_at(self, a):
        return self.classes.get(int(a, 16))

    def call(self, method, params):
        assert method == "starknet_call"
        return [self.pub]


class FakeRunner:
    """Key-free sncast stand-in. Every run asserts a durable, unlinked Starknet reservation is already on disk; the
    'send' builds the transaction like sncast does from the guard's argv, then `tamper` may corrupt it."""

    def __init__(self, ledger_path, sn, tamper=None, fee=None, est=None, crash_on_send=False, pending=False):
        self.path, self.sn, self.tamper, self.fee, self.est, self.crash = Path(ledger_path), sn, tamper, fee, est, \
            crash_on_send
        self.pending = pending  # sent but not yet included: no receipt, nonce unchanged
        self.keystore, self.descriptor = SN_KS, g.sn_account_descriptor(sn_binding(), True)
        self.calls = []

    def run(self, args, cwd=None):
        recs = [json.loads(line) for line in self.path.read_text().splitlines()]
        res = [r for r in recs if r["type"] == "reserve" and r["chain"] == g.STARKNET_SEPOLIA
               and not any(x.get("ref") == r["seq"] and x["type"] in ("sn-sent", "outcome", "void") for x in recs)]
        assert len(res) == 1, "sncast ran without exactly one durable unlinked reservation"
        self.calls.append(list(args))
        if "--dry-run" in args:
            return [dict(self.est or SN_FEE_EST)]
        if self.crash:
            os._exit(97)
        opt = {args[i]: args[i + 1] for i in range(len(args) - 1) if args[i].startswith("--")}
        cd = [int(x) for x in args[args.index("--calldata") + 1:args.index("--l1-gas")]]
        tx = {"type": "INVOKE", "version": "0x3", "sender_address": SN_ACCT, "nonce": hex(int(opt["--nonce"])),
              "calldata": [hex(x) for x in [1, int(opt["--contract-address"], 16), SNCAST_VOTE_SELECTOR, len(cd), *cd]],
              "resource_bounds": {r: {"max_amount": hex(int(opt[f"--{r.replace('_', '-')}"])),
                                      "max_price_per_unit": hex(int(opt[f"--{r.replace('_', '-')}-price"]))}
                                  for r in g.SN_RESOURCES},
              "tip": hex(int(opt["--tip"])), "paymaster_data": [], "account_deployment_data": [],
              "signature": ["0x1", "0x2"], "nonce_data_availability_mode": "L1", "fee_data_availability_mode": "L1"}
        rc = {"finality_status": "ACCEPTED_ON_L2", "execution_status": "SUCCEEDED", "block_number": 7,
              "actual_fee": {"amount": hex(self.fee if self.fee is not None else 10**15), "unit": "FRI"}}
        if self.tamper:
            self.tamper(tx, rc)
        h = "0x" + os.urandom(31).hex()
        self.sn.txs[h] = tx
        if not self.pending:
            self.sn.rcs[h] = rc
            self.sn.nonce_v += 1
        return [{"command": "invoke", "transaction_hash": h, "type": "response"}]


def vote_args():
    return ["invoke", "--url", "http://sn.invalid", "--contract-address", SN_GOV, "--function", "vote",
            "--calldata", "5", "1"]


def sn_vote(led, sn, runner, fault=g._no_fault):
    return g.sn_send(led, LIM, sn_binding(), "vote", vote_args(), sn, runner, out=lambda s: None, fault=fault,
                     polls=(2, 0))


class StarknetSendTest(LedgerCase):
    def test_selectors_match_installed_sncast(self):
        self.assertEqual(g.sn_selector("vote"), SNCAST_VOTE_SELECTOR)
        self.assertEqual(g.sn_selector("deployContract"), SNCAST_DEPLOY_SELECTOR)

    def test_vote_ok_explicit_bounds_nonce_and_reservation_first(self):
        sn = FakeSn()
        sn.nonce_v = 0
        r = FakeRunner(self.path, sn)
        o = sn_vote(self.led, sn, r)
        self.assertEqual((o["status"], o["cost"]), (1, str(10**15)))
        self.assertIn("--dry-run", r.calls[0])
        send = r.calls[1]
        self.assertNotIn("--max-fee", send)
        self.assertEqual(send[send.index("--nonce") + 1], "0")
        self.assertEqual(send[send.index("--tip") + 1], "0")
        types = [x["type"] for x in self.led.records]
        self.assertEqual(types, ["reserve", "sn-bounds", "sn-sent", "outcome"])
        cap = int(LIM["starknet"]["kinds"]["vote"]["max_fee_fri"])
        self.assertEqual(int(self.led.records[0]["max_cost"]), cap)
        self.assertLessEqual(int(self.led.records[1]["max_liability"]), cap)

    def tampered(self, tamper, pat):
        sn = FakeSn()
        r = FakeRunner(self.path, sn, tamper=tamper)
        with self.assertRaisesRegex(g.Refused, pat):
            sn_vote(self.led, sn, r)
        (a,) = self.led.open_reserves(g.STARKNET_SEPOLIA)  # not credited
        self.assertIsNone(self.led.outcome(a["seq"]))
        self.assertEqual(self.led.exposure(g.STARKNET_SEPOLIA), int(a["max_cost"]))
        self.assertTrue(self.led.incidents())
        r2 = FakeRunner(self.path, sn)
        with self.assertRaisesRegex(g.Refused, "incident"):
            sn_vote(self.led, sn, r2)  # persistent stop; sncast never runs again
        self.assertEqual(r2.calls, [])

    def test_wrong_sender(self):
        self.tampered(lambda tx, rc: tx.update(sender_address="0x" + "99" * 31), "sender_address")

    def test_wrong_nonce(self):
        self.tampered(lambda tx, rc: tx.update(nonce="0x5"), "nonce")

    def test_wrong_payload(self):
        self.tampered(lambda tx, rc: tx["calldata"].__setitem__(-1, "0x0"), "calldata")

    def test_wrong_resource_bounds_or_tip_or_type(self):
        self.tampered(lambda tx, rc: tx["resource_bounds"]["l2_gas"].update(max_amount=hex(10**12)), "resource bound")

    def test_tip_set(self):
        self.tampered(lambda tx, rc: tx.update(tip="0x1"), "tip")

    def test_wrong_type_or_version(self):
        self.tampered(lambda tx, rc: tx.update(version="0x1"), "type/version")

    def test_missing_fields(self):
        for k in ("sender_address", "resource_bounds", "nonce", "calldata", "paymaster_data"):
            with self.subTest(k=k):
                self.setUp()
                self.tampered(lambda tx, rc, k=k: tx.pop(k), "missing or malformed")
                self.tearDown()

    def test_signed_liability_above_reservation_refused(self):
        b = {r: {"max_amount": "0x10", "max_price_per_unit": "0x10"} for r in g.SN_RESOURCES}
        txd = {"type": "INVOKE", "version": "0x3", "nonce": "0x0", "sender_address": "0x1", "resource_bounds": b,
               "tip": "0x0", "paymaster_data": [], "account_deployment_data": [], "nonce_data_availability_mode": "L1",
               "fee_data_availability_mode": "L1"}
        a = {"nonce": 0, "max_cost": str(3 * 256), "expect": {"type": "INVOKE", "sender_address": "0x1"}}
        g.sn_verify_tx(txd, {}, a, b)
        with self.assertRaisesRegex(g.Refused, "liability"):
            g.sn_verify_tx(txd, {}, dict(a, max_cost=str(3 * 256 - 1)), b)

    def test_receipt_fee_unit_missing_or_wrong(self):
        self.tampered(lambda tx, rc: rc["actual_fee"].update(unit="WEI"), "not FRI")

    def test_actual_fee_above_cap_recorded_and_stops(self):  # N-5
        cap = int(LIM["starknet"]["kinds"]["vote"]["max_fee_fri"])
        sn = FakeSn()
        with self.assertRaisesRegex(g.Refused, r"above the reserved maximum.*\(N-5\)"):
            sn_vote(self.led, sn, FakeRunner(self.path, sn, fee=cap + 1))
        (a,) = self.led.attempts(g.STARKNET_SEPOLIA)
        self.assertEqual(int(self.led.outcome(a["seq"])["cost"]), cap + 1)  # accurate ledger, not silent credit
        r2 = FakeRunner(self.path, sn)
        with self.assertRaisesRegex(g.Refused, "N-5"):
            sn_vote(self.led, sn, r2)
        with self.assertRaisesRegex(g.Refused, "N-5"):
            g.precheck(self.led, LIM, g.SEPOLIA, "payer", "l1-execute", tx(), g.GWEI, 0)
        self.assertEqual(r2.calls, [])

    def test_estimate_above_cap_voids_after_dry_run_only(self):
        sn = FakeSn()
        r = FakeRunner(self.path, sn, est=dict(SN_FEE_EST, l2_gas_consumed=10**8))
        with self.assertRaisesRegex(g.Refused, "fresh estimate"):
            sn_vote(self.led, sn, r)
        self.assertEqual(len(r.calls), 1)
        self.assertIn("--dry-run", r.calls[0])
        self.assertEqual([x["type"] for x in self.led.records], ["reserve", "void"])

    def test_precheck_refusal_reaches_no_sncast(self):
        sn = FakeSn()
        for _ in range(int(LIM["starknet"]["kinds"]["vote"]["attempts_max"])):
            rr = self.led.append({"type": "reserve", "chain": g.STARKNET_SEPOLIA, "role": "starknet", "from": SN_ACCT,
                                  "kind": "vote", "nonce": 0, "value": "0", "max_cost": "1", "hash": ""})
            self.led.append({"type": "void", "ref": rr["seq"], "chain": g.STARKNET_SEPOLIA, "reason": "t"})
        r = FakeRunner(self.path, sn)
        with self.assertRaisesRegex(g.Refused, "attempt cap"):
            sn_vote(self.led, sn, r)
        self.assertEqual(r.calls, [])


class StarknetIdentityTest(unittest.TestCase):
    def test_identity_checked_before_key_access(self):
        b, sn = sn_binding(), FakeSn()
        self.assertTrue(g.sn_check_identity(sn, b, "vote", SN_KS))
        with self.assertRaisesRegex(g.Refused, "keystore_sha256"):
            g.sn_check_identity(sn, b, "vote", SN_KS + b" ")
        sn.pub = "0x" + "77" * 31
        with self.assertRaisesRegex(g.Refused, "public key"):
            g.sn_check_identity(sn, b, "vote", SN_KS)
        sn = FakeSn()
        sn.classes[int(SN_ACCT, 16)] = 0x1234
        with self.assertRaisesRegex(g.Refused, "class"):
            g.sn_check_identity(sn, b, "vote", SN_KS)
        with self.assertRaisesRegex(g.Refused, "already has code"):
            g.sn_check_identity(sn, b, "account-deploy", SN_KS)
        sn.classes.clear()
        self.assertFalse(g.sn_check_identity(sn, b, "account-deploy", SN_KS))
        with self.assertRaisesRegex(g.Refused, "class None"):
            g.sn_check_identity(sn, b, "vote", SN_KS)

    def test_descriptor_is_generated_from_the_binding(self):
        b = sn_binding()
        for deployed in (True, False):
            d = json.loads(g.sn_account_descriptor(b, deployed))
            self.assertEqual(d["variant"], {"legacy": False, "public_key": SN_PUB, "type": "open_zeppelin",
                                            "version": 1})
            self.assertEqual(d["deployment"]["class_hash"], SN_CLASS)
            if deployed:
                self.assertEqual(int(d["deployment"]["address"], 16), int(SN_ACCT, 16))
            else:
                self.assertEqual(d["deployment"]["salt"], SN_SALT_A)

    def test_sncast_runner_uses_frozen_bytes_and_late_password(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "seen.json"
            exe = Path(d) / "fake-sncast"
            exe.write_text("#!/usr/bin/env python3\nimport json, os, sys\na = sys.argv\n"
                           "ks = open(a[a.index('--keystore') + 1], 'rb').read()\n"
                           "acct = open(a[a.index('--account') + 1]).read()\n"
                           f"json.dump({{'argv': a, 'ks': ks.decode(), 'acct': acct, "
                           f"'pw': os.environ.get('KEYSTORE_PASSWORD'), 'env_keys': sorted(os.environ)}}, "
                           f"open({str(out)!r}, 'w'))\n"
                           "print(json.dumps({'transaction_hash': '0x1'}))\n")
            exe.chmod(0o700)
            pw_calls = []
            r = g.Sncast(SN_KS, g.sn_account_descriptor(sn_binding(), True), lambda: pw_calls.append(1) or "pw", str(exe))
            self.assertEqual(pw_calls, [])  # constructing the runner reads no password
            with mock.patch.dict(os.environ, {"T2_D3_SENTINEL": "x", "STARKNET_ACCOUNTS_FILE": "/x"}):
                self.assertEqual(g._find_hash(r.run(["invoke"])), "0x1")
            seen = json.loads(out.read_text())
            # D-3: minimal environment (allowlist + KEYSTORE_PASSWORD only)
            self.assertTrue(all(k == "KEYSTORE_PASSWORD" or k in g.CHILD_ENV_KEYS or k.startswith(g.CHILD_ENV_PREFIXES)
                                for k in seen["env_keys"]), seen["env_keys"])
            self.assertEqual((seen["ks"].encode(), seen["acct"].encode(), seen["pw"]),
                             (SN_KS, g.sn_account_descriptor(sn_binding(), True), "pw"))
            self.assertTrue(seen["argv"][seen["argv"].index("--account") + 1].startswith("/dev/fd/"))
            self.assertEqual(pw_calls, [1])


class StarknetRpcErrorTest(unittest.TestCase):  # N-6
    def rpc(self, err):
        class R:
            def call(self, method, params):
                raise g.RpcError(method, err)
        s = g.StarknetRpc("http://x.invalid")
        s.rpc = R()
        return s

    def test_exact_code_20_only(self):
        self.assertEqual(self.rpc({"code": 20, "message": "Contract not found"}).nonce("0x1"), 0)
        for err in ({"code": 21, "message": "error 20"}, {"code": 24, "message": "Block not found (20)"},
                    {"code": -32603, "message": "Contract not found"}, "20"):
            with self.assertRaisesRegex(g.Refused, "not CONTRACT_NOT_FOUND"):
                self.rpc(err).nonce("0x1")

    def test_receipt_and_tx_only_code_29_is_unknown(self):
        self.assertIsNone(self.rpc({"code": 29, "message": "Transaction hash not found"}).receipt("0x1"))
        self.assertIsNone(self.rpc({"code": 29, "message": "Transaction hash not found"}).transaction("0x1"))
        with self.assertRaises(g.Refused):
            self.rpc({"code": -32603, "message": "x"}).receipt("0x1")
        with self.assertRaises(g.Refused):
            self.rpc({"code": 21, "message": "x"}).class_hash_at("0x1")
        self.assertIsNone(self.rpc({"code": 20, "message": "x"}).class_hash_at("0x1"))


# ---------------------------------------------------------------- N-3 ledger dir, F4/N-7 faucet sources + register
class LedgerDirTest(unittest.TestCase):
    def test_bound_dir_and_override_refused(self):
        b = binding()
        self.assertEqual(g.ledger_path(b).parent, Path(b["ledger_dir"]))
        scope = g.Scope("m", "b", "t", "d", b, json.dumps(b), "h")
        env = g.bound_env(scope, LIM)
        self.assertEqual(env["T2_LEDGER_DIR"], b["ledger_dir"])
        with self.assertRaisesRegex(g.Refused, "T2_LEDGER_DIR is pre-set"):
            g.refuse_overrides(env, {"T2_LEDGER_DIR": "/tmp/other-ledger"})
        with self.assertRaisesRegex(g.Refused, "T2_OP_VAULT is pre-set"):
            g.refuse_overrides(env, {"T2_OP_VAULT": "other-vault"})
        os.environ["T2_LEDGER_DIR"] = "/tmp/other-ledger"
        try:
            self.assertEqual(g.ledger_path(b).parent, Path(b["ledger_dir"]))  # the environment never selects it
        finally:
            del os.environ["T2_LEDGER_DIR"]
        for bad in ("relative/dir", "~/.local/state/ekubo-t2", "/a/../b", "/a/", "", None):
            with self.assertRaisesRegex(g.Refused, "ledger_dir"):
                g.ledger_path(dict(b, ledger_dir=bad))


class FaucetBindingTest(unittest.TestCase):
    def refused(self, mutate, pat):
        b = binding()
        mutate(b)
        with self.assertRaisesRegex(g.Refused, pat):
            g.check_binding(b, LIM)

    def test_empty_or_incomplete_sources_refused(self):
        self.refused(lambda b: b.update(faucet_sources=[]), "faucet_sources is empty")
        self.refused(lambda b: b["faucet_sources"][0].update(eligibility=""), "lacks eligibility")
        self.refused(lambda b: b["faucet_sources"][0].update(operator=""), "lacks operator")
        self.refused(lambda b: b["faucet_sources"][0].update(paid=True), "must be free")
        self.refused(lambda b: b["faucet_sources"][0].update(mainnet_prerequisite=True), "must be free")
        self.refused(lambda b: b["faucet_sources"][0].update(operator="agent"), "named human operator")
        self.refused(lambda b: b["faucet_sources"].pop(), "needs one or two")
        self.refused(lambda b: b["faucet_sources"].extend(
            [dict(b["faucet_sources"][1], source=f"extra-{i}") for i in range(2)]), "needs one or two")
        self.refused(lambda b: b["faucet_sources"][0].update(chain="eip155:1"), "unfunded chain")
        self.refused(lambda b: b.update(op_vault=""), "op_vault")
        self.refused(lambda b: b["starknet"].update(keystore_sha256=None), "keystore_sha256")
        self.refused(lambda b: b["starknet"].update(account_public_key="0x0"), "public key")

    def test_unbound_template_refused(self):
        b = json.loads((T2 / "binding/t2-binding.json").read_text())
        with self.assertRaisesRegex(g.Refused, "not BOUND"):
            g.check_binding(b, LIM)
        self.assertEqual(b["faucet_sources"], [])
        self.assertIsNone(b["starknet"]["keystore_sha256"])


class FaucetRegisterTest(LedgerCase):
    def test_register_rules(self):
        b, c, src = binding(), "eip155:97", "free-eip155:97"
        mx = int(next(f["max"] for f in b["funding_recipients"] if f["chain"] == c and f["role"] == "payer"))
        r1 = g.faucet_record(self.led, b, c, "payer", src, "requested")
        with self.assertRaisesRegex(g.Refused, "already requested"):
            g.faucet_record(self.led, b, c, "payer", src, "requested")
        with self.assertRaisesRegex(g.Refused, "not a bound free source"):
            g.faucet_record(self.led, b, c, "payer", "paid-faucet", "requested")
        with self.assertRaisesRegex(g.Refused, "not a bound funding recipient"):
            g.faucet_record(self.led, b, c, "safe-signer-a", src, "requested")
        self.assertEqual(g.faucet_register(self.led)[(c, "payer")]["pending"], 1)
        b2 = copy.deepcopy(b)
        b2["faucet_sources"].append(dict(b2["faucet_sources"][1], source="second-97"))
        g.check_binding(b2, LIM)
        with self.assertRaisesRegex(g.Refused, "still pending"):  # a second source while the first is pending
            g.faucet_record(self.led, b2, c, "payer", "second-97", "requested")
        g.faucet_record(self.led, b, c, "payer", src, "denied", ref=r1["seq"])
        reg = g.faucet_register(self.led)[(c, "payer")]
        self.assertEqual((reg["requests"], reg["pending"], reg["denied"], reg["received"]), (1, 0, 1, 0))
        with self.assertRaisesRegex(g.Refused, "already requested"):  # denied still counts: no repeat
            g.faucet_record(self.led, b, c, "payer", src, "requested")
        r2 = g.faucet_record(self.led, b, c, "deployer", src, "requested")
        with self.assertRaisesRegex(g.Refused, "one open request"):
            g.faucet_record(self.led, b, c, "deployer", src, "received", amount=1, ref=r1["seq"])
        dmx = int(next(f["max"] for f in b["funding_recipients"] if f["chain"] == c and f["role"] == "deployer"))
        with self.assertRaisesRegex(g.Refused, "above its maximum"):
            g.faucet_record(self.led, b, c, "deployer", src, "received", amount=dmx + 1, ref=r2["seq"])
        self.assertEqual(g.faucet_register(self.led)[(c, "deployer")]["received"], dmx + 1)  # recorded truthfully
        with self.assertRaisesRegex(g.Refused, "incident"):
            g.precheck(self.led, LIM, 97, "payer", "execute", tx(gas=100_000), g.GWEI, 0)
        self.assertLess(0, mx)


# ---------------------------------------------------------------- R2-D: DEPLOY_ACCOUNT address derived before secrets
# Independent vectors. PEDERSEN: starkware crypto test vector. REAL: DEPLOY_ACCOUNT transactions ACCEPTED_ON_L1 on
# Starknet Sepolia (read-only public RPC, EKU-1272): tx hash, block, class, salt, constructor calldata, receipt
# contract_address. The first uses the pinned OpenZeppelin class with an sncast-style 8-byte salt; the other two are
# other account classes (single- and multi-felt constructors) that the guard must refuse to bind. SNCAST: address
# printed by installed sncast 0.62.1 `account create` (local fake node, throwaway key since deleted).
PEDERSEN_VECTOR = (0x03d937c035c878245caf64531a5756109c53068da139362728feb561405371cb,
                   0x0208a0a10250e382e1e4bbe2880906c2791bf6275695e02fbbc6aeff9cd8b31a,
                   0x030e480bed5fe53fa909cc0f8c4d99b8f9f2c016be4c41e13a4848797979c662)
REAL_DEPLOY_ACCOUNT = (
    ("0x12ba9a89eaf532eb980040dd30bb999ff9a045c8e666918dac91f5cf90c9d4b", 16117795,
     "0x5b4b537eaa2399e3aa99c4e2e0208ebd6c71bc1467938cd52c798c601e43564", "0x5bdb506a105905a3",
     ["0x2ab910bc01ba2b04a38aab0a8e689a0f37c59888b90776e0a192461c2dfc77c"],
     "0x1279b582fca886d3d17ea4f57bebafe80072acfa0bd92189017f8994d9fe954"),
    ("0x5b567957d260b0d285be72cf3cb2fe69b5ad7cb45007f8dd8db720aac5b00f4", 16315969,
     "0x5400e90f7e0ae78bd02c77cd75527280470e2fe19c54970dd79dc37a9d3645c",
     "0x4956b5add51684853fed1b7ae9f8b4893d1944a7b03a0b201c6dad477fae97d",
     ["0x4956b5add51684853fed1b7ae9f8b4893d1944a7b03a0b201c6dad477fae97d"],
     "0x1f81c43c1d86b5d12978f52143c99b06798c3095688a8698471cbaf6ca7dd0d"),
    ("0x482a355cf4637c6b22c88ec0784daa29a254168f9b0b28843ffdc06aa302072", 16331907,
     "0x6e150953b26271a740bf2b6e9bca17cc52c68d765f761295de51ceb8526ee72",
     "0x2cd7471358418aa7c420fb09e939fd70c7c149593a1941cb25718d2e789fd93",
     ["0x1", "0x2", "0x2cd7471358418aa7c420fb09e939fd70c7c149593a1941cb25718d2e789fd93",
      "0x1b765299a040e6ab10e483baaa75b6b705135e4fee4ec909b7c2c6847fffbf3"],
     "0x54e7f81b46ce9a250daed8198e72b00ba5b72136b25e176c48a9b6296b99741"),
)
SNCAST_CREATE_VECTOR = ("0x6a6daaf5102cb6ac", "0x11a31162172947f8c5331f2b117ca6c08ab77896fd520b0b1c2ed28a1c0fd8b",
                        "0x03d630abda0eb052b3f18d01df5530d8b22b691fd7ba4bdb2008d7a8496096e8")


def set_sn_address(b, addr, recipient=True):
    b["roles"]["starknet_account"] = b["starknet"]["account"] = addr
    if recipient:
        next(f for f in b["funding_recipients"] if f["chain"] == "starknet:SN_SEPOLIA")["address"] = addr
    return b


def r2d_mutations():
    """(name, mutate, refusal pattern): each makes the bound address differ from the derived one or drops a field."""
    other = "0x0" + "ab" * 31
    pub, cls, salt = int(SN_PUB, 16), int(SN_CLASS, 16), int(SN_SALT_A, 16)
    ctor_variant = hex(g.sn_contract_address(cls, salt, [pub, 0]))
    deployer_variant = hex(g.sn_contract_address(cls, salt, [pub], 0x1))
    derived = "DEPLOY_ACCOUNT address derived"
    st = lambda **kw: (lambda b: b["starknet"].update(kw))  # noqa: E731
    rcp = lambda b: next(f for f in b["funding_recipients"] if f["chain"] == "starknet:SN_SEPOLIA")  # noqa: E731
    return [
        ("all address fields wrong", lambda b: set_sn_address(b, other), derived),
        ("roles.starknet_account wrong", lambda b: b["roles"].update(starknet_account=other), derived),
        ("starknet.account wrong", st(account=other), derived),
        ("funding recipient wrong", lambda b: rcp(b).update(address=other), derived),
        ("salt 0x1 (CFO probe)", st(account_salt="0x1"), derived),
        ("salt 0x2 (CFO probe)", st(account_salt="0x2"), derived),
        ("public key wrong", st(account_public_key="0x" + "77" * 31), derived),
        ("unsupported class (real Sepolia account class)", st(account_class_hash=REAL_DEPLOY_ACCOUNT[1][2]),
         "not the supported OpenZeppelin account class"),
        ("arbitrary class", st(account_class_hash="0x" + "5b" * 31), "not the supported OpenZeppelin account class"),
        ("address of another constructor [pub, 0]", lambda b: set_sn_address(b, ctor_variant), derived),
        ("address with a non-zero deployer", lambda b: set_sn_address(b, deployer_variant), derived),
        ("missing public key", lambda b: b["starknet"].pop("account_public_key"), "public key is not a non-zero felt"),
        ("missing class hash", lambda b: b["starknet"].pop("account_class_hash"), "class hash is not a non-zero felt"),
        ("missing salt", lambda b: b["starknet"].pop("account_salt"), "salt is not a non-zero felt"),
        ("missing starknet.account", lambda b: b["starknet"].pop("account"), "starknet.account is not a non-zero felt"),
        ("missing roles.starknet_account", lambda b: b["roles"].pop("starknet_account"),
         "roles.starknet_account is not a non-zero felt"),
        ("missing Starknet funding recipient", lambda b: b.update(funding_recipients=[
            f for f in b["funding_recipients"] if f["chain"] != "starknet:SN_SEPOLIA"]), "no Starknet funding recipient"),
        ("missing account_type", lambda b: b["starknet"].pop("account_type"), "account_type"),
    ]


class StarknetAddressDerivationTest(unittest.TestCase):
    """CFO R2-D: the DEPLOY_ACCOUNT address is derived from public data and matched before any secret is touched."""

    def test_known_independent_vectors(self):
        a, b, h = PEDERSEN_VECTOR
        self.assertEqual(g.sn_pedersen(a, b), h)
        for txh, _blk, cls, salt, ctor, addr in REAL_DEPLOY_ACCOUNT:
            with self.subTest(tx=txh):
                self.assertEqual(g.sn_contract_address(int(cls, 16), int(salt, 16), [int(x, 16) for x in ctor]),
                                 int(addr, 16))
        txh, _blk, cls, salt, (pub,), addr = REAL_DEPLOY_ACCOUNT[0]
        self.assertEqual(int(cls, 16), int(g.SN_OZ_ACCOUNT_CLASS, 16))  # the pinned class is a real Sepolia account
        self.assertEqual(g.sn_account_address({"account_public_key": pub, "account_class_hash": cls,
                                               "account_salt": salt}), int(addr, 16))
        salt, pub, addr = SNCAST_CREATE_VECTOR
        self.assertEqual(g.sn_account_address({"account_public_key": pub, "account_class_hash": g.SN_OZ_ACCOUNT_CLASS,
                                               "account_salt": salt}), int(addr, 16))
        for txh, _blk, cls, salt, ctor, _addr in REAL_DEPLOY_ACCOUNT[1:]:  # other classes: refused, not guessed
            with self.assertRaisesRegex(g.Refused, "not the supported OpenZeppelin account class"):
                g.sn_account_address({"account_public_key": ctor[-1], "account_class_hash": cls, "account_salt": salt})

    def test_address_is_reduced_below_the_l2_address_bound(self):
        real = g.sn_hash_on_elements
        with mock.patch.object(g, "sn_hash_on_elements", lambda xs: g.SN_ADDRESS_BOUND + 5 if len(xs) == 5 else real(xs)):
            self.assertEqual(g.sn_contract_address(1, 2, [3]), 5)

    def test_valid_binding_passes_every_boundary(self):
        b = sn_binding()
        g.check_binding(b, LIM)
        g.check_sn_account_binding(b)
        self.assertEqual(int(b["roles"]["starknet_account"], 16), g.sn_account_address(b["starknet"]))
        sn = FakeSn()
        self.assertTrue(g.sn_check_identity(sn, b, "vote", SN_KS))
        sn.classes.clear()
        self.assertFalse(g.sn_check_identity(sn, b, "account-deploy", SN_KS))

    def test_every_mismatch_refused_in_binding_identity_and_descriptor(self):
        for name, mutate, pat in r2d_mutations():
            with self.subTest(name=name):
                b = sn_binding()
                mutate(b)
                with self.assertRaises(g.Refused):
                    g.check_binding(b, LIM)  # full binding validation (bind and every authorized command)
                with self.assertRaisesRegex(g.Refused, pat):
                    g.check_sn_account_binding(b)
                sn = FakeSn()
                sn.classes.clear()
                with self.assertRaisesRegex(g.Refused, pat):
                    g.sn_check_identity(sn, b, "account-deploy", SN_KS)
                with self.assertRaisesRegex(g.Refused, pat):
                    g.sn_account_descriptor(b, False)

    def test_bind_refuses_inconsistent_keys_before_deriving_anything(self):
        b = sn_binding()
        keys = {"deployer": A["deployer"], "bootstrap": A["bootstrap"], "payer": A["payer"],
                "safe_owners": [A["sa"], A["sb"], A["sc"]], "starknet_account": SN_ACCT, "op_vault": "t2-unit-test",
                "ledger_dir": b["ledger_dir"], "starknet_public_key": SN_PUB, "starknet_account_class_hash": SN_CLASS,
                "starknet_account_salt": SN_SALT_A, "starknet_keystore_sha256": g.sha256_hex(SN_KS),
                "evm_keystore_sha256": b["evm_keystore_sha256"], "faucet_sources": faucet_sources()}
        calls = []
        stubs = {"sn_addr": lambda kind, cd, acct: calls.append(kind) or "0x" + f"{len(calls):02x}" * 31,
                 "create_addr": lambda d, n: "0x" + f"{0x60 + n:02x}" * 20,
                 "safe_addr": lambda o, s, c: "0x" + "70" * 20}
        with mock.patch.multiple(g, **stubs):
            out = g.build_binding(keys, LIM, "0x00")
            self.assertEqual((out["evm_keystore_sha256"], len(calls)), (b["evm_keystore_sha256"], 3))
            for k, v in (("starknet_account_salt", "0x1"), ("starknet_public_key", "0x" + "77" * 31),
                         ("starknet_account", "0x0" + "ab" * 31), ("starknet_account_class_hash", "0x" + "5b" * 31)):
                calls.clear()
                with self.subTest(k=k), self.assertRaises(g.Refused):
                    g.build_binding(dict(keys, **{k: v}), LIM, "0x00")
                self.assertEqual(calls, [])  # refused before any token/staker/governor derivation
            with self.assertRaisesRegex(g.Refused, "evm_keystore_sha256"):
                g.build_binding(dict(keys, evm_keystore_sha256={"deployer": "ab" * 32}), LIM, "0x00")


FAKE_SNCAST = r'''#!/usr/bin/env python3
import json, os, sys
open(os.environ.get("T2_TEST_CALLS") or sys.argv[0] + ".calls", "a").write(json.dumps(sys.argv[1:]) + "\n")
print(json.dumps({"type": "error", "error": "fake sncast: nothing is signed or sent"}))
'''


class SnRunPrePasswordTest(unittest.TestCase):
    """R2-D at the `sn` command boundary (sn_run): with a wrong or incomplete identity, the password source is never
    constructed or called, sncast never runs (no dry-run, no account deploy) and the ledger is never written."""

    URL = "http://sn.invalid"

    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.w = Path(d.name)
        (self.w / "t2-starknet.json").write_bytes(SN_KS)
        self.exe = self.w / "sncast"
        self.exe.write_text(FAKE_SNCAST)
        self.exe.chmod(0o700)

    def run_sn(self, b):
        made, pw = [], []

        def factory():
            made.append(1)
            return lambda: pw.append(1) or "pw"
        sn = FakeSn()
        sn.classes.clear()  # undeployed account
        led = self.w / "ledger" / "l.jsonl"
        err = None
        try:
            g.sn_run(b, LIM, "account-deploy", ["account", "deploy", "--url", self.URL], sn, self.URL,
                     self.w / "t2-starknet.json", factory, led, exe=str(self.exe), polls=(1, 0))
        except g.Refused as e:
            err = str(e)
        calls = Path(str(self.exe) + ".calls")
        n = len(calls.read_text().splitlines()) if calls.exists() else 0
        recs = [json.loads(x)["type"] for x in led.read_text().splitlines()] if led.exists() else []
        if calls.exists():
            calls.unlink()
        return err, len(made), len(pw), n, recs

    def test_mismatch_reaches_no_password_signer_or_ledger(self):
        for name, mutate, pat in r2d_mutations():
            with self.subTest(name=name):
                b = sn_binding()
                mutate(b)
                err, made, pw, n, recs = self.run_sn(b)
                self.assertRegex(err or "", pat)
                self.assertEqual((made, pw, n, recs), (0, 0, 0, []))

    def test_sn_send_itself_refuses_before_any_reservation(self):
        for name, mutate, pat in r2d_mutations()[:11]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as d:
                b = sn_binding()
                mutate(b)
                sn = FakeSn()
                p = Path(d) / "l.jsonl"
                with g.Ledger(p) as led:
                    r = FakeRunner(p, sn)
                    with self.assertRaisesRegex(g.Refused, pat):
                        g.sn_send(led, LIM, b, "vote", vote_args(), sn, r, out=lambda s: None, polls=(1, 0))
                    self.assertEqual((r.calls, led.records), ([], []))

    def test_valid_identity_reaches_password_only_after_the_reservation(self):
        err, made, pw, n, recs = self.run_sn(sn_binding())
        self.assertIn("sncast failed", err)
        self.assertEqual((made, pw, n, recs), (1, 1, 1, ["reserve", "void"]))  # one dry-run, then void


# ---------------------------------------------------------------- D-1: killing tests for the CSO EKU-1270 survivors
class DeltaCoverageTest(LedgerCase):
    """One test per surviving mutant of cso_delta_mutants.py (EKU-1270 D-1)."""

    def test_sn_linked_but_unincluded_send_blocks_the_next_send(self):  # SN open_reserves precheck
        sn = FakeSn()
        with self.assertRaisesRegex(g.Refused, "no receipt"):
            sn_vote(self.led, sn, FakeRunner(self.path, sn, pending=True))
        (a,) = self.led.open_reserves(g.STARKNET_SEPOLIA)
        self.assertTrue(self.led.tx_hash(a))
        self.assertEqual(sn.nonce_v, self.led.mined_count(g.STARKNET_SEPOLIA, SN_ACCT))  # nonce does not block it
        r2 = FakeRunner(self.path, sn)
        with self.assertRaisesRegex(g.Refused, "unknown outcome"):
            sn_vote(self.led, sn, r2)
        self.assertEqual((r2.calls, len(self.led.attempts(g.STARKNET_SEPOLIA))), ([], 1))

    def test_sn_receipt_without_finality_is_not_credited(self):  # SN finality required
        for status in ("RECEIVED", "PRE_CONFIRMED", "CANDIDATE", None):
            with self.subTest(status=status):
                self.setUp()
                sn = FakeSn()
                with self.assertRaisesRegex(g.Refused, "no receipt"):
                    sn_vote(self.led, sn, FakeRunner(self.path, sn, tamper=lambda tx, rc: rc.update(
                        finality_status=status)))
                (a,) = self.led.open_reserves(g.STARKNET_SEPOLIA)
                self.assertEqual((self.led.outcome(a["seq"]), self.led.incidents()), (None, []))
                self.assertEqual(self.led.exposure(g.STARKNET_SEPOLIA), int(a["max_cost"]))
                self.tearDown()

    def test_sn_account_deployment_data_on_invoke(self):  # SN account_deployment_data checked
        StarknetSendTest.tampered(self, lambda tx, rc: tx.update(account_deployment_data=["0x1"]),
                                  "account deployment data")

    def test_sn_data_availability_mode(self):  # D-3 containment
        for k in ("nonce_data_availability_mode", "fee_data_availability_mode"):
            with self.subTest(k=k):
                self.setUp()
                StarknetSendTest.tampered(self, lambda tx, rc, k=k: tx.update({k: "L2"}), "data availability")
                self.tearDown()

    def test_sn_tx_without_bounds_record_is_not_credited(self):  # SN sn-bounds required
        sn, b = FakeSn(), sn_binding()
        cap = int(LIM["starknet"]["kinds"]["vote"]["max_fee_fri"])
        rec = self.led.append({"type": "reserve", "chain": g.STARKNET_SEPOLIA, "role": "starknet", "from": SN_ACCT,
                               "kind": "vote", "step": "vote", "nonce": 0, "value": "0", "max_cost": str(cap),
                               "hash": "", "expect": g.sn_expected("vote", vote_args(), b)})
        h = "0x" + "4e" * 31
        self.led.append({"type": "sn-sent", "ref": rec["seq"], "hash": h})
        bounds = g.sn_bounds(SN_FEE_EST, cap)
        sn.txs[h] = {"type": "INVOKE", "version": "0x3", "sender_address": SN_ACCT, "nonce": "0x0",
                     "calldata": [hex(x) for x in [1, int(SN_GOV, 16), SNCAST_VOTE_SELECTOR, 2, 5, 1]],
                     "resource_bounds": {r: {f: hex(v) for f, v in bounds[r].items()} for r in g.SN_RESOURCES},
                     "tip": "0x0", "paymaster_data": [], "account_deployment_data": [],
                     "nonce_data_availability_mode": "L1", "fee_data_availability_mode": "L1"}
        sn.rcs[h] = {"finality_status": "ACCEPTED_ON_L2", "execution_status": "SUCCEEDED", "block_number": 7,
                     "actual_fee": {"amount": hex(10**15), "unit": "FRI"}}
        with self.assertRaisesRegex(g.Refused, "no reserved resource bounds"):
            g.sn_settle(self.led, sn, rec)
        self.assertEqual((self.led.outcome(rec["seq"]), len(self.led.incidents())), (None, 1))
        with self.assertRaisesRegex(g.Refused, "incident"):
            sn_vote(self.led, sn, FakeRunner(self.path, sn))

    def test_evm_publish_failure_keeps_the_reservation(self):  # EVM publish failure is not a void
        class Down(EvmFake):
            def publish(self, raw):
                self.published.append(raw)
                raise ConnectionError("node unreachable")
        ch, s = Down(g.SEPOLIA, A["payer"]), FakeSigner(self.path)
        with self.assertRaisesRegex(g.Refused, "stays reserved"):
            run_send(self.led, ch, s)
        (a,) = self.led.open_reserves(g.SEPOLIA)
        self.assertEqual([r["type"] for r in self.led.records], ["reserve", "signed"])
        self.assertEqual(self.led.exposure(g.SEPOLIA, "payer"), int(a["max_cost"]))
        s2 = FakeSigner(self.path)
        with self.assertRaisesRegex(g.Refused, "unknown outcome"):
            run_send(self.led, EvmFake(g.SEPOLIA, A["payer"]), s2)
        self.assertEqual(s2.calls, 0)
        g.reconcile_evm(self.led, {g.SEPOLIA: EvmFake(g.SEPOLIA, A["payer"], mine=False)}, {"payer": A["payer"]},
                        False, "0xdd", out=lambda s: None)
        self.assertEqual(self.led.open_reserves(g.SEPOLIA), [a])  # an absent receipt never releases it

    def test_evm_twin_void_needs_the_twins_receipt(self):  # EVM twin void without receipt
        a = self.reserve(97, "payer", "execute", 100_000, open_=True, n=0)
        b = self.reserve(97, "payer", "execute", 100_000, open_=True, n=0)
        ch = FakeChain(97)
        ch.nonces[A["payer"]] = 1
        with self.assertRaisesRegex(g.Refused, "NOT in the ledger"):
            g.reconcile_evm(self.led, {97: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)
        self.assertEqual((self.led.outcome(a["seq"]), self.led.outcome(b["seq"])), (None, None))
        ch.receipts[b["hash"]] = {"status": "0x1", "gasUsed": hex(21_000), "effectiveGasPrice": hex(g.GWEI),
                                  "from": A["payer"], "transactionHash": b["hash"], "blockNumber": "0x5", "logs": []}
        g.reconcile_evm(self.led, {97: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)
        self.assertEqual((self.led.outcome(a["seq"])["type"], self.led.outcome(b["seq"])["type"]), ("void", "outcome"))

    def test_evm_receipt_from_or_hash_must_match(self):  # EVM receipt from/hash matched
        for k, bad in (("from", A["bootstrap"]), ("transactionHash", "0x" + "ee" * 32)):
            with self.subTest(k=k):
                self.setUp()
                a = self.reserve(97, "payer", "execute", 100_000, open_=True)
                ch = FakeChain(97)
                ch.nonces[A["payer"]] = 1
                rc = {"status": "0x1", "gasUsed": hex(21_000), "effectiveGasPrice": hex(g.GWEI), "from": A["payer"],
                      "transactionHash": a["hash"], "blockNumber": "0x5", "logs": []}
                ch.receipts[a["hash"]] = dict(rc, **{k: bad})
                with self.assertRaisesRegex(g.Refused, "does not match the reserved signer or hash"):
                    g.reconcile_evm(self.led, {97: ch}, {"payer": A["payer"]}, False, "0xd", out=lambda s: None)
                self.assertIsNone(self.led.outcome(a["seq"]))
                self.tearDown()

    def test_evm_pending_nonce_differs_from_latest(self):  # EVM pending != latest refused
        class Pending(EvmFake):
            def nonce(self, a, tag="latest"):
                return super().nonce(a) + (1 if tag == "pending" else 0)
        ch, s = Pending(g.SEPOLIA, A["payer"]), FakeSigner(self.path)
        with self.assertRaisesRegex(g.Refused, "nonce ambiguity"):
            run_send(self.led, ch, s)
        self.assertEqual((s.calls, self.led.records, ch.published), (0, [], []))

    def test_faucet_result_needs_a_matching_open_request(self):  # faucet result without request
        b, c, src = binding(), "eip155:97", "free-eip155:97"
        r = g.faucet_record(self.led, b, c, "payer", src, "requested")
        for ref in (999, r["seq"] + 1, None):
            for status in ("received", "denied"):
                with self.subTest(ref=ref, status=status), self.assertRaisesRegex(g.Refused, "one open request"):
                    g.faucet_record(self.led, b, c, "payer", src, status, amount=1, ref=ref)
        with self.assertRaisesRegex(g.Refused, "one open request"):  # open request of another recipient
            g.faucet_record(self.led, b, c, "deployer", src, "received", amount=1, ref=r["seq"])
        self.assertEqual(g.faucet_register(self.led)[(c, "payer")]["pending"], 1)
        self.assertEqual(len(self.led.records), 1)


# ---------------------------------------------------------------- E-1: post-return DEPLOY_ACCOUNT tamper (CSO EKU-1274)
class FakeDeployRunner(FakeRunner):
    """Key-free `sncast account deploy` stand-in: the send builds the DEPLOY_ACCOUNT sncast would produce from the
    bound identity (no --nonce; nonce 0), and its receipt carries the deployed contract_address. Like Sncast, every
    run reads the password once; `tamper` may then corrupt the returned tx or receipt."""

    def __init__(self, ledger_path, sn, tamper=None):
        super().__init__(ledger_path, sn, tamper=tamper)
        self.descriptor = g.sn_account_descriptor(sn_binding(), False)
        self.pw = 0

    def run(self, args, cwd=None):
        recs = [json.loads(line) for line in self.path.read_text().splitlines()]
        res = [r for r in recs if r["type"] == "reserve" and r["chain"] == g.STARKNET_SEPOLIA
               and not any(x.get("ref") == r["seq"] and x["type"] in ("sn-sent", "outcome", "void") for x in recs)]
        assert len(res) == 1, "sncast ran without exactly one durable unlinked reservation"
        self.calls.append(list(args))
        self.pw += 1
        if "--dry-run" in args:
            return [dict(SN_FEE_EST)]
        opt = {args[i]: args[i + 1] for i in range(len(args) - 1) if args[i].startswith("--")}
        tx = {"type": "DEPLOY_ACCOUNT", "version": "0x3", "nonce": "0x0", "class_hash": SN_CLASS,
              "contract_address_salt": SN_SALT_A, "constructor_calldata": [SN_PUB],
              "resource_bounds": {r: {"max_amount": hex(int(opt[f"--{r.replace('_', '-')}"])),
                                      "max_price_per_unit": hex(int(opt[f"--{r.replace('_', '-')}-price"]))}
                                  for r in g.SN_RESOURCES},
              "tip": hex(int(opt["--tip"])), "paymaster_data": [], "signature": ["0x1", "0x2"],
              "nonce_data_availability_mode": "L1", "fee_data_availability_mode": "L1"}
        rc = {"finality_status": "ACCEPTED_ON_L2", "execution_status": "SUCCEEDED", "block_number": 7,
              "contract_address": SN_ACCT, "actual_fee": {"amount": hex(10**15), "unit": "FRI"}}
        if self.tamper:
            self.tamper(tx, rc)
        h = "0x" + os.urandom(31).hex()
        self.sn.txs[h], self.sn.rcs[h] = tx, rc
        self.sn.nonce_v += 1
        if int(rc["contract_address"], 16) == int(SN_ACCT, 16):
            self.sn.classes[int(SN_ACCT, 16)] = int(tx["class_hash"], 16)
        return [{"command": "account deploy", "transaction_hash": h, "type": "response"}]


DEPLOY_URL = "http://sn.invalid"


def deploy_args():
    return ["account", "deploy", "--url", DEPLOY_URL]


class DeployAccountTamperTest(LedgerCase):
    """CSO EKU-1274 E-1: the returned DEPLOY_ACCOUNT must equal the reserved intent field by field (class hash, salt,
    constructor calldata and the receipt contract_address). A tampered return persists an incident, credits no
    outcome, keeps the reservation at its maximum and stops every later send before sncast or the password."""

    def deploy(self, runner, sn):
        return g.sn_send(self.led, LIM, sn_binding(), "account-deploy", deploy_args(), sn, runner,
                         out=lambda s: None, polls=(2, 0))

    def undeployed(self):
        sn = FakeSn()
        sn.classes.clear()
        return sn

    def test_clean_deploy_is_credited(self):  # control: the same path with an untampered return
        sn = self.undeployed()
        r = FakeDeployRunner(self.path, sn)
        o = self.deploy(r, sn)
        self.assertEqual((o["status"], o["cost"]), (1, str(10**15)))
        self.assertEqual([x["type"] for x in self.led.records], ["reserve", "sn-bounds", "sn-sent", "outcome"])
        a = self.led.records[0]
        self.assertEqual(a["expect"], {"type": "DEPLOY_ACCOUNT", "class_hash": hex(int(SN_CLASS, 16)),
                                       "contract_address_salt": hex(int(SN_SALT_A, 16)),
                                       "constructor_calldata": [hex(int(SN_PUB, 16))],
                                       "contract_address": hex(int(SN_ACCT, 16))})
        self.assertEqual((self.led.incidents(), self.led.open_reserves(g.STARKNET_SEPOLIA)), ([], []))
        self.assertEqual(r.calls[1][:4], deploy_args())
        self.assertNotIn("--nonce", r.calls[1])
        self.assertEqual(r.pw, 2)  # dry-run + send
        self.assertEqual(self.led.exposure(g.STARKNET_SEPOLIA), 10**15)

    def tampered(self, tamper, pat):
        sn = self.undeployed()
        r = FakeDeployRunner(self.path, sn, tamper=tamper)
        with self.assertRaisesRegex(g.Refused, pat):
            self.deploy(r, sn)
        self.assertEqual(r.pw, 2)
        (a,) = self.led.open_reserves(g.STARKNET_SEPOLIA)
        self.assertEqual(a["kind"], "account-deploy")
        self.assertIsNone(self.led.outcome(a["seq"]))  # no outcome credited
        self.assertFalse([x for x in self.led.records if x["type"] in ("outcome", "void")])
        cap = int(LIM["starknet"]["kinds"]["account-deploy"]["max_fee_fri"])
        self.assertEqual(int(a["max_cost"]), cap)
        self.assertEqual(self.led.exposure(g.STARKNET_SEPOLIA), cap)  # reservation retained at its maximum
        (inc,) = self.led.incidents()
        self.assertEqual((inc["ref"], inc["hash"]), (a["seq"], self.led.tx_hash(a)))
        self.assertIn("does not match the reserved intent", inc["reason"])
        persisted = [json.loads(x) for x in self.path.read_text().splitlines()]
        self.assertEqual([x["type"] for x in persisted], ["reserve", "sn-bounds", "sn-sent", "incident"])
        n = len(persisted)
        # the next in-process send is refused before sncast runs or the password is read
        r2 = FakeDeployRunner(self.path, sn)
        with self.assertRaisesRegex(g.Refused, "incident"):
            self.deploy(r2, sn)
        self.assertEqual((r2.calls, r2.pw), ([], 0))
        # and so is the next `sn` command through sn_run with the real Sncast runner (fresh ledger handle)
        self.led.__exit__()
        w = Path(self.dir.name)
        (w / "t2-starknet.json").write_bytes(SN_KS)
        exe = w / "sncast"
        exe.write_text(FAKE_SNCAST)
        exe.chmod(0o700)
        pw = []
        for kind, args in (("account-deploy", deploy_args()), ("vote", vote_args())):
            with self.subTest(next_kind=kind):
                sn2 = self.undeployed() if kind == "account-deploy" else FakeSn()
                with self.assertRaisesRegex(g.Refused, "incident"):
                    g.sn_run(sn_binding(), LIM, kind, args, sn2, DEPLOY_URL, w / "t2-starknet.json",
                             lambda: (lambda: pw.append(1) or "pw"), self.path, exe=str(exe), polls=(1, 0))
        self.assertEqual((pw, Path(str(exe) + ".calls").exists()), ([], False))
        self.assertEqual(len(self.path.read_text().splitlines()), n)  # nothing further written

    def test_wrong_class_hash(self):
        self.tampered(lambda tx, rc: tx.update(
            class_hash="0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f"), "class_hash")

    def test_wrong_contract_address_salt(self):
        self.tampered(lambda tx, rc: tx.update(contract_address_salt="0x1"), "contract_address_salt")

    def test_wrong_constructor_calldata(self):
        self.tampered(lambda tx, rc: tx.update(constructor_calldata=[SN_PUB, "0x0"]), "constructor_calldata")

    def test_wrong_receipt_contract_address(self):
        self.tampered(lambda tx, rc: rc.update(contract_address="0x" + "77" * 31), "contract_address ")


# ---------------------------------------------------------------- D-2: bound EVM keystores; D-3 containment
FAKE_CAST = r'''#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv
out = os.environ.get("T2_TEST_OUT") or a[0] + ".seen"
ks = open(a[a.index("--keystore") + 1], "rb").read()
pw = open(a[a.index("--password-file") + 1], "rb").read()
json.dump({"ks": ks.decode(), "pw": pw.decode(), "env_keys": sorted(os.environ), "pid": os.getpid(),
           "keystore_arg": a[a.index("--keystore") + 1]}, open(out, "w"))
if os.path.exists(a[0] + ".hang"):
    time.sleep(60)
print("0x02f8")
'''


class EvmKeystoreBindingTest(LedgerCase):
    def mk(self, role="payer", data=None):
        d = Path(self.dir.name) / "ks"
        d.mkdir(exist_ok=True)
        (d / f"t2-{role}.json").write_bytes(EVM_KS[role] if data is None else data)
        exe = Path(self.dir.name) / "cast"
        exe.write_text(FAKE_CAST)
        exe.chmod(0o700)
        self.pw = []
        return g.Signer(d, "v", lambda r: self.pw.append(r) or b"pw-" + r.encode(),
                        keystore_sha256=binding()["evm_keystore_sha256"], exe=str(exe)), d, exe

    def test_binding_requires_distinct_digests_for_the_signing_roles(self):
        def refused(mutate):
            b = binding()
            mutate(b)
            with self.assertRaisesRegex(g.Refused, "keystore"):
                g.check_binding(b, LIM)
        refused(lambda b: b.pop("evm_keystore_sha256"))
        refused(lambda b: b["evm_keystore_sha256"].pop("bootstrap"))
        refused(lambda b: b["evm_keystore_sha256"].update({"safe-signer-a": "ab" * 32}))
        refused(lambda b: b["evm_keystore_sha256"].update(payer="AB" * 32))
        refused(lambda b: b["evm_keystore_sha256"].update(payer=None))
        refused(lambda b: b["evm_keystore_sha256"].update(payer=b["evm_keystore_sha256"]["deployer"]))
        refused(lambda b: b["evm_keystore_sha256"].update(payer=b["starknet"]["keystore_sha256"]))
        t = json.loads((T2 / "binding/t2-binding.json").read_text())
        self.assertEqual(t["evm_keystore_sha256"], {"deployer": None, "bootstrap": None, "payer": None})  # UNBOUND

    def test_wrong_missing_or_unbound_keystore_refused_before_password_and_reservation(self):
        for name, data, digests, pat in (
                ("substituted bytes", EVM_KS["bootstrap"], None, "differs from the bound keystore_sha256"),
                ("one extra byte", EVM_KS["payer"] + b" ", None, "differs from the bound keystore_sha256"),
                ("missing file", None, None, "missing"),
                ("no bound digest", EVM_KS["payer"], {}, "no bound keystore_sha256"),
                ("empty bound digest", EVM_KS["payer"], {"payer": ""}, "no bound keystore_sha256")):
            with self.subTest(name=name):
                self.setUp()
                s, d, exe = self.mk(data=data)
                if data is None:
                    (d / "t2-payer.json").unlink()
                if digests is not None:
                    s.keystore_sha256 = digests
                ch = EvmFake(g.SEPOLIA, A["payer"])
                with self.assertRaisesRegex(g.Refused, pat):
                    g.send_plan(self.led, LIM, binding(), "l1exec", g.SEPOLIA, "payer", [l1exec_tx()], ch, s, "0xdd",
                                out=lambda s: None)
                self.assertEqual((self.pw, self.led.records, ch.published), ([], [], []))
                self.assertFalse(Path(str(exe) + ".seen").exists())  # cast never ran
                self.tearDown()

    def test_frozen_bytes_are_signed_even_if_the_file_is_swapped_after_the_check(self):
        s, d, exe = self.mk()
        s.freeze("payer")
        (d / "t2-payer.json").write_bytes(EVM_KS["bootstrap"])  # path swap between check and decrypt
        self.assertEqual(s.sign("payer", g.SEPOLIA, l1exec_tx(), g.GWEI, 0), "0x02f8")
        seen = json.loads(Path(str(exe) + ".seen").read_text())
        self.assertEqual((seen["ks"].encode(), seen["pw"], self.pw), (EVM_KS["payer"], "pw-payer", ["payer"]))
        self.assertTrue(seen["keystore_arg"].startswith("/dev/fd/"))

    def test_signer_child_gets_a_minimal_environment(self):  # D-3
        s, d, exe = self.mk()
        with mock.patch.dict(os.environ, {"T2_D3_SENTINEL": "x", "ETH_RPC_URL": "http://x.invalid",
                                          "STARKNET_SEPOLIA_RPC_URL": "http://y.invalid"}):
            s.sign("payer", g.SEPOLIA, l1exec_tx(), g.GWEI, 0)
        keys = json.loads(Path(str(exe) + ".seen").read_text())["env_keys"]
        self.assertTrue(all(k in g.CHILD_ENV_KEYS or k.startswith(g.CHILD_ENV_PREFIXES) for k in keys), keys)
        self.assertIn("PATH", keys)

    def test_hung_signer_child_is_killed_and_the_slot_stays_unlinked(self):  # D-3
        s, d, exe = self.mk()
        Path(str(exe) + ".hang").write_text("")
        s.timeout = 1
        with self.assertRaises(subprocess.TimeoutExpired):
            run_send(self.led, EvmFake(g.SEPOLIA, A["payer"]), s)
        pid = json.loads(Path(str(exe) + ".seen").read_text())["pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)  # killed and reaped, not left running
        (a,) = self.led.open_reserves(g.SEPOLIA)
        self.assertIsNone(self.led.link(a))
        with self.assertRaisesRegex(g.Refused, "permanent stop"):
            g.reconcile_evm(self.led, {g.SEPOLIA: EvmFake(g.SEPOLIA, A["payer"])}, {"payer": A["payer"]}, True,
                            "0xdd", out=lambda s: None)

    @unittest.skipUnless(shutil.which("cast"), "cast needed")
    def test_real_cast_signs_from_the_frozen_memfd_keystore(self):
        """Throwaway local keystore (never funded, deleted with the temp dir): cast reads the keystore from /dev/fd."""
        d = Path(self.dir.name) / "real"
        d.mkdir()
        pw = "eku-1272-throwaway-" + os.urandom(6).hex()
        out = subprocess.run(["cast", "wallet", "new", str(d), "t2-payer.json"], capture_output=True, text=True,
                             env={**os.environ, "CAST_PASSWORD": pw}, check=True)
        out = out.stdout + out.stderr
        addr = next(line.split()[-1] for line in out.splitlines() if line.startswith("Address:")).lower()
        data = (d / "t2-payer.json").read_bytes()
        s = g.Signer(d, "v", lambda r: pw.encode(), keystore_sha256={"payer": g.sha256_hex(data)})
        s.freeze("payer")
        (d / "t2-payer.json").write_bytes(b"{}")  # the swapped file is never read again
        t = g.PlannedTx(addr, "0x" + "aa" * 20, 0, "0xdeadbeef", 2, 50_000)
        g.verify_signed(g.decode_signed(s.sign("payer", 97, t, 3 * g.GWEI, 1)), 97, t, 3 * g.GWEI, 1)


# ---------------------------------------------------------------- installed sncast compatibility (local fake node)
class _Node(http.server.BaseHTTPRequestHandler):
    state: dict = {}

    def log_message(self, *a):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["content-length"])))
        st = self.state
        m, p = req["method"], req.get("params")
        if isinstance(p, list):  # the guard sends positional params, sncast named ones
            names = {"starknet_getNonce": ("block_id", "contract_address"),
                     "starknet_getClassHashAt": ("block_id", "contract_address"),
                     "starknet_getTransactionReceipt": ("transaction_hash",),
                     "starknet_getTransactionByHash": ("transaction_hash",)}.get(m, ())
            p = dict(zip(names, p))
        p = p if isinstance(p, dict) else {}
        res, err = None, None
        acct = st["account"]
        if m == "starknet_specVersion":
            res = "0.10.0"
        elif m == "starknet_chainId":
            res = g.SN_CHAIN_ID_SEPOLIA
        elif m == "starknet_getNonce":
            a = int(p.get("contract_address", "0x0"), 16)
            if a == acct and not st["deployed"]:
                err = {"code": 20, "message": "Contract not found"}
            else:
                res = hex(st["nonce"])
        elif m == "starknet_getClassHashAt":
            a = int(p.get("contract_address", "0x0"), 16)
            if a == acct and not st["deployed"]:
                err = {"code": 20, "message": "Contract not found"}
            else:
                res = hex(st["account_class"]) if a == acct else "0x61dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f"
        elif m == "starknet_getClass":
            res = {"sierra_program": ["0x1"], "contract_class_version": "0.1.0",
                   "entry_points_by_type": {"EXTERNAL": [], "L1_HANDLER": [], "CONSTRUCTOR": []}, "abi": "[]"}
        elif m == "starknet_estimateFee":
            res = [{"l1_gas_consumed": "0x10", "l1_gas_price": "0x3b9aca00", "l2_gas_consumed": "0xf4240",
                    "l2_gas_price": "0x2540be400", "l1_data_gas_consumed": "0x80", "l1_data_gas_price": "0x3b9aca00",
                    "overall_fee": "0x0", "unit": "FRI"}]
        elif m in ("starknet_addInvokeTransaction", "starknet_addDeployAccountTransaction"):
            tx = dict(next(iter(p.values())))
            h = "0x" + os.urandom(31).hex()
            st["sent"].append(tx)
            st["txs"][int(h, 16)] = tx
            if m == "starknet_addDeployAccountTransaction":
                st["deployed"] = True
                res = {"transaction_hash": h, "contract_address": hex(acct)}
            else:
                res = {"transaction_hash": h}
            st["nonce"] += 1
        elif m == "starknet_getTransactionByHash":
            tx = st["txs"].get(int(p.get("transaction_hash", "0x0"), 16))
            res = tx
            if tx is None:
                err = {"code": 29, "message": "Transaction hash not found"}
        elif m == "starknet_getTransactionReceipt":
            if int(p.get("transaction_hash", "0x0"), 16) in st["txs"]:
                res = {"finality_status": "ACCEPTED_ON_L2", "execution_status": "SUCCEEDED", "block_number": 9,
                       "actual_fee": {"amount": hex(10**14), "unit": "FRI"}, "contract_address": hex(acct)}
            else:
                err = {"code": 29, "message": "Transaction hash not found"}
        elif m == "starknet_getEvents":
            res = {"events": []}
        elif m == "starknet_call":
            res = [hex(st["pubkey"])]
        elif m == "starknet_blockNumber":
            res = 9
        else:
            err = {"code": -32601, "message": f"unsupported {m}"}
        out = {"jsonrpc": "2.0", "id": req.get("id")}
        if err:
            out["error"] = err
        else:
            out["result"] = res
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


@unittest.skipUnless(shutil.which("sncast") and shutil.which("script") and os.environ.get("T2_SKIP_SNCAST") != "1",
                     "installed sncast + util-linux script needed")
class SncastCompatTest(unittest.TestCase):
    """The guard's real Sncast runner + sn_send against the INSTALLED sncast and a local fake node, with a throwaway
    keystore created for this test only (never funded, never sent anywhere): argv, explicit bounds, --nonce, the
    generated descriptor and the on-chain transaction verification all agree with sncast's actual behaviour."""

    def test_account_deploy_vote_and_udc_deploy(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        w = Path(d.name)
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Node)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        url = f"http://127.0.0.1:{srv.server_address[1]}"
        _Node.state = {"account": -1, "deployed": False, "nonce": 0, "sent": [], "txs": {}, "account_class": 0,
                       "pubkey": 0}
        pw = "eku-1268-throwaway-" + os.urandom(6).hex()
        cmd = f"{shutil.which('sncast')} --keystore {w}/ks.json --account {w}/acct.json --json account create --url {url}"
        feed = subprocess.Popen(["script", "-q", "-c", cmd, "/dev/null"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        import time as _t
        _t.sleep(3)
        out, _ = feed.communicate(f"{pw}\n{pw}\n", timeout=60)
        created = json.loads((w / "acct.json").read_text())
        addr = next(json.loads(line[line.index("{"):])["address"] for line in out.splitlines()
                    if '"address"' in line)
        b = set_sn_address(sn_binding(), addr)
        b["starknet"].update(account_public_key=created["variant"]["public_key"],
                             account_class_hash=created["deployment"]["class_hash"],
                             account_salt=created["deployment"]["salt"],
                             keystore_sha256=g.sha256_hex((w / "ks.json").read_bytes()))
        _Node.state.update(account=int(addr, 16), account_class=int(created["deployment"]["class_hash"], 16),
                           pubkey=int(created["variant"]["public_key"], 16))
        # R2-D: sncast's own address for the created account equals the guard's public-only derivation
        self.assertEqual(int(addr, 16), g.sn_account_address(b["starknet"]))
        self.assertEqual(int(created["deployment"]["class_hash"], 16), int(g.SN_OZ_ACCOUNT_CLASS, 16))
        g.check_sn_account_binding(b)
        sn = g.StarknetRpc(url)
        ks = (w / "ks.json").read_bytes()
        with g.Ledger(w / "ledger.jsonl") as led:
            for kind, args in (
                ("account-deploy", ["account", "deploy", "--url", url]),
                ("vote", ["invoke", "--url", url, "--contract-address", SN_GOV, "--function", "vote", "--calldata",
                          "5", "1"]),
                ("deploy-staker", ["deploy", "--url", url, "--class-hash", g.SN_CLASSES["staker"], "--salt", g.SN_SALT,
                                   "--unique", "--constructor-calldata", b["starknet"]["token"]]),
            ):
                g.sn_validate(kind, args, b, url)
                deployed = g.sn_check_identity(sn, b, kind, ks)
                runner = g.Sncast(ks, g.sn_account_descriptor(b, deployed), lambda: pw)
                o = g.sn_send(led, LIM, b, kind, args, sn, runner, out=lambda s: None, polls=(3, 0.2))
                self.assertEqual(o["status"], 1, kind)
                sent = _Node.state["sent"][-1]
                bounds = next(r["bounds"] for r in led.records if r["type"] == "sn-bounds"
                              and r["ref"] == led.attempts(g.STARKNET_SEPOLIA)[-1]["seq"])
                for r in g.SN_RESOURCES:  # sncast signed exactly the guard's explicit bounds
                    self.assertEqual(int(sent["resource_bounds"][r]["max_amount"], 16), int(bounds[r]["max_amount"]))
                self.assertEqual(int(sent["tip"], 16), 0)
            self.assertEqual(int(_Node.state["sent"][0]["constructor_calldata"][0], 16),
                             int(created["variant"]["public_key"], 16))
            self.assertEqual(int(_Node.state["sent"][1]["sender_address"], 16), int(addr, 16))
            self.assertEqual(int(_Node.state["sent"][1]["nonce"], 16), 1)
            self.assertEqual([int(x, 16) for x in _Node.state["sent"][2]["calldata"][1:3]],
                             [int(g.SN_UDC, 16), SNCAST_DEPLOY_SELECTOR])
            # a substituted keystore is refused before any password access
            with self.assertRaisesRegex(g.Refused, "keystore_sha256"):
                g.sn_check_identity(sn, b, "vote", ks.replace(b"{", b"{ ", 1))
            # a wrong password makes sncast fail on the dry-run: in-process void, nothing sent
            n0 = len(_Node.state["sent"])
            runner = g.Sncast(ks, g.sn_account_descriptor(b, True), lambda: "wrong-password")
            with self.assertRaisesRegex(g.Refused, "sncast failed"):
                g.sn_send(led, LIM, b, "vote", ["invoke", "--url", url, "--contract-address", SN_GOV, "--function",
                                                "vote", "--calldata", "6", "1"], sn, runner, out=lambda s: None,
                          polls=(3, 0.2))
            self.assertEqual(len(_Node.state["sent"]), n0)
            self.assertEqual(led.records[-1]["type"], "void")


if __name__ == "__main__":
    unittest.main()
