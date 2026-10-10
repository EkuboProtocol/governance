#!/usr/bin/env python3
"""EKU-1261 T2 corrected budget (F2): one enumerated slot schedule -> `t2-limits.json` (enforced by t2_guard.py).

Every transaction slot, including retries, failed, manual and incident attempts, is listed with its signed gas limit
maximum (EVM) or its signed max fee (Starknet). Worst case = every attempt used, every attempt charged its full
signed limit at the gas-price ceiling (Monad charges the gas limit anyway), plus every CCIP fee at its maximum.
The worst case must fit every role subcap, chain cap and the Starknet fee cap, or this script fails: the schedule
is revised within the caps, never the caps raised. Exact integer/Decimal arithmetic only.

Usage: t2_budget.py            print the budget tables (markdown) and the worst-case margins
       t2_budget.py --write    regenerate t2-limits.json
       t2_budget.py --check    fail if t2-limits.json differs from the schedule
"""

from __future__ import annotations

import json
import sys
from decimal import Decimal
from pathlib import Path

GWEI, ETHER = 10**9, 10**18
SEPOLIA, BNB, MONAD = 11155111, 97, 10143

# Acquisition caps and role subcaps (CFO EKU-1234, unchanged; native test units, zero valuation).
CHAIN_CAP = {SEPOLIA: 25 * ETHER // 100, BNB: 5 * ETHER // 100, MONAD: 2 * ETHER}
ROLE_CAP = {
    SEPOLIA: {"deployer": 6 * ETHER // 100, "bootstrap": ETHER // 100, "payer": 18 * ETHER // 100},
    BNB: {"deployer": 3 * ETHER // 100, "payer": 2 * ETHER // 100},
    MONAD: {"deployer": 14 * ETHER // 10, "payer": 6 * ETHER // 10},
}
GAS_PRICE_CEILING = {SEPOLIA: 20 * GWEI, BNB: 3 * GWEI, MONAD: 200 * GWEI}
CCIP = {"fee_max_wei": 2 * 10**15, "fee_total_wei": 18 * 10**15, "messages_max": 9}

# kind: (role, planned, extra attempts (retry/manual/incident), gas_max per signed tx, why)
# gas_max is the per-transaction signed gas-limit ceiling: forge's simulated estimate (x1.3 buffer) must be below it.
EVM_SCHEDULE: dict[int, dict[str, tuple[str, int, int, int, str]]] = {
    SEPOLIA: {
        "deploy-proxy": ("deployer", 1, 0, 800_000, "E0 test StarknetOwnerProxy (nonce 0); a failure stops T2"),
        "deploy-sender": ("deployer", 1, 0, 1_900_000, "E1 sender (nonce 1); a failure stops T2"),
        "ping-request": ("bootstrap", 3, 0, 145_000, "2 pings + 1 DeadlineTooFar ping; no retry (bootstrap subcap)"),
        "handoff": ("bootstrap", 1, 0, 65_000, "one-way handoff; a failure stops T2"),
        "l1-execute": ("payer", 6, 2, 230_000, "2 P1 + 4 P2 proxy executions; 2 retries (no low-gas probe)"),
        "dispatch": ("payer", 9, 2, 520_000, "3 pings + 2 proofs + 4 P2 = 9 messages; 2 failed-dispatch retries"),
    },
    BNB: {
        "deploy-target": ("deployer", 2, 0, 700_000, "B0-B1 dummy targets"),
        "safe-create": ("deployer", 1, 0, 550_000, "B2 Safe 1.4.1 proxy (CREATE2)"),
        "deploy-executor": ("deployer", 1, 0, 2_600_000, "B3 executor"),
        "transfer": ("deployer", 2, 1, 80_000, "dummy ownership -> executor; 1 retry"),
        "execute": ("payer", 2, 1, 300_000, "proof + set43; 1 retry"),
        "safe-cancel": ("payer", 1, 1, 250_000, "cancel set99; 1 incident cancel reserved"),
        "manual-exec": ("payer", 1, 1, 900_000, "DeadlineTooFar recovery; 1 retry or delivery-failure recovery"),
    },
    MONAD: {
        "deploy-target": ("deployer", 4, 0, 700_000, "M0-M3 dummy targets"),
        "safe-create": ("deployer", 1, 0, 550_000, "M4 Safe 1.4.1 proxy (CREATE2)"),
        "deploy-executor": ("deployer", 1, 0, 2_600_000, "M5 executor"),
        "transfer": ("deployer", 4, 1, 80_000, "dummy ownership -> executor; 1 retry"),
        "execute": ("payer", 2, 1, 300_000, "proof + set42; 1 retry"),
        "safe-cancel": ("payer", 0, 1, 250_000, "1 incident cancel reserved"),
        "manual-exec": ("payer", 0, 1, 900_000, "1 delivery-failure recovery reserved"),
    },
}

# Starknet Sepolia (fri; 1 STRK = 1e18 fri). kind: (planned, max attempts, signed max fee, why)
STRK = ETHER
# L2->L1 message L1 gas measured by snforge (src/t2_l1_message_test.cairo): ~25.4k per message + ~1.38k per felt;
# at the 2026-10-10 Starknet Sepolia L1 gas price (0x1fdd70ce24fd fri) that is ~2 STRK per small message, which is
# why the 469-felt padded op (~23 STRK) is no longer sent for real and P2 is split into two proposals.
SN_SCHEDULE: dict[str, tuple[int, int, int, str]] = {
    "account-deploy": (1, 2, 1 * STRK, "OZ account deploy"),
    "declare-token": (1, 2, 2 * STRK, "T2VotingToken class (test-only)"),
    "declare-staker": (1, 2, 4 * STRK, "governance::staker::Staker class 0x0244c221..dade"),
    "declare-governor": (1, 2, 5 * STRK, "Governor class 0x044e2e3d..7401 (= mainnet class)"),
    "deploy-token": (1, 2, 1 * STRK, "fixed supply, all to t2-starknet"),
    "deploy-staker": (1, 2, 1 * STRK, "Staker(token)"),
    "deploy-governor": (1, 2, 1 * STRK, "Governor(staker, T2 config)"),
    "approve": (1, 2, STRK // 2, "token approve(staker, supply)"),
    "stake": (1, 2, STRK // 2, "stake_amount(self, supply)"),
    "propose": (3, 4, STRK // 2, "P1, P2a, P2b"),
    "vote": (3, 4, 3 * STRK // 10, "P1, P2a, P2b"),
    "execute-p1": (1, 2, 7 * STRK, "P1: 2 messages, 20 + 30 felts (~120k L1 gas, ~4.2 STRK now)"),
    "execute-p2a": (1, 2, 7 * STRK, "P2a: 97 set42 + 97 set99 (2 x 22 felts, ~112k L1 gas, ~3.9 STRK now)"),
    "execute-p2b": (1, 2, 7 * STRK, "P2b: 97 set43 + 10143 set42 (22 + 35 felts, ~130k L1 gas, ~4.5 STRK now)"),
}
SN_RETRIES_MAX = 2
SN_FEE_CAP = 48 * STRK
SN_BALANCE_CAP = 50 * STRK
SN_NON_FEE_RESERVE = 2 * STRK  # no STRK is staked any more (test token); kept as balance >= next max fee margin
T2_TOKEN_SUPPLY = 1_000 * ETHER  # test voting token units, not STRK


def limits() -> dict:
    evm = {}
    for cid, kinds in EVM_SCHEDULE.items():
        evm[str(cid)] = {
            "chain_cap_wei": str(CHAIN_CAP[cid]),
            "gas_price_ceiling_wei": str(GAS_PRICE_CEILING[cid]),
            "role_cap_wei": {r: str(v) for r, v in ROLE_CAP[cid].items()},
            "attempts_max": sum(p + x for (_, p, x, _, _) in kinds.values()),
            "kinds": {k: {"role": r, "planned": p, "attempts_max": p + x, "gas_max": g,
                          **({"value_max_wei": str(CCIP["fee_max_wei"])} if k == "dispatch" else {})}
                      for k, (r, p, x, g, _) in kinds.items()},
        }
    return {
        "schema": "ekubo-t2-limits-v1",
        "generated_by": "l1_proxy/script/t2/t2_budget.py",
        "evm": evm,
        "ccip": {k: str(v) if k != "messages_max" else v for k, v in CCIP.items()},
        "starknet": {
            "balance_cap_fri": str(SN_BALANCE_CAP), "fee_cap_fri": str(SN_FEE_CAP),
            "non_fee_reserve_fri": str(SN_NON_FEE_RESERVE), "retries_max": SN_RETRIES_MAX,
            "attempts_max": sum(p for (p, _, _, _) in SN_SCHEDULE.values()) + SN_RETRIES_MAX,
            "stake_amount": str(T2_TOKEN_SUPPLY), "token_supply": str(T2_TOKEN_SUPPLY),
            "kinds": {k: {"planned": p, "attempts_max": a, "max_fee_fri": str(f)}
                      for k, (p, a, f, _) in SN_SCHEDULE.items()},
        },
    }


def worst_case() -> tuple[list[str], list[str]]:
    rows, errors = [], []
    for cid, kinds in EVM_SCHEDULE.items():
        price = GAS_PRICE_CEILING[cid]
        per_role: dict[str, int] = {r: 0 for r in ROLE_CAP[cid]}
        gas_total = 0
        for k, (r, p, x, g, why) in kinds.items():
            n = p + x
            cost = n * g * price + (n * CCIP["fee_max_wei"] if k == "dispatch" else 0)
            per_role[r] += cost
            gas_total += n * g
            rows.append(f"| {cid} | {k} | {r} | {p} | {x} | {g:,} | {n * g:,} | {Decimal(cost) / ETHER} | {why} |")
        for r, v in per_role.items():
            cap = ROLE_CAP[cid][r]
            line = f"chain {cid} {r}: worst {Decimal(v) / ETHER} / cap {Decimal(cap) / ETHER} " \
                   f"(margin {Decimal(cap - v) / ETHER})"
            (errors if v > cap else rows).append(("FAIL " if v > cap else "") + line)
        total = sum(per_role.values())
        line = f"chain {cid} total: gas {gas_total:,} worst {Decimal(total) / ETHER} / cap {Decimal(CHAIN_CAP[cid]) / ETHER}"
        (errors if total > CHAIN_CAP[cid] else rows).append(line)
    planned = sum(p * f for (p, _, f, _) in SN_SCHEDULE.values())
    if planned > SN_FEE_CAP:
        errors.append(f"Starknet planned max fees {Decimal(planned) / STRK} > 48 STRK")
    biggest_two = sorted((f for (_, _, f, _) in SN_SCHEDULE.values()), reverse=True)[:SN_RETRIES_MAX]
    rows.append(f"Starknet planned max fees {Decimal(planned) / STRK} STRK of {Decimal(SN_FEE_CAP) / STRK}; headroom "
                f"{Decimal(SN_FEE_CAP - planned) / STRK} for <= {SN_RETRIES_MAX} retries (largest two would need "
                f"{Decimal(sum(biggest_two)) / STRK}: a retry that does not fit the aggregate is refused, i.e. stop)")
    for k, (p, a, f, _) in SN_SCHEDULE.items():
        if f > 10 * STRK:
            errors.append(f"Starknet {k} max fee above 10 STRK")
    if SN_FEE_CAP + SN_NON_FEE_RESERVE > SN_BALANCE_CAP:
        errors.append("Starknet fee cap + reserve > 50 STRK")
    return rows, errors


def counts() -> dict:
    evm = {cid: sum(p + x for (_, p, x, _, _) in k.values()) for cid, k in EVM_SCHEDULE.items()}
    evm_planned = {cid: sum(p for (_, p, _, _, _) in k.values()) for cid, k in EVM_SCHEDULE.items()}
    return {"evm_attempts_max": evm, "evm_attempts_total": sum(evm.values()), "evm_planned": evm_planned,
            "evm_planned_total": sum(evm_planned.values()),
            "starknet_planned": sum(p for (p, _, _, _) in SN_SCHEDULE.values()),
            "starknet_attempts_max": sum(p for (p, _, _, _) in SN_SCHEDULE.values()) + SN_RETRIES_MAX,
            "ccip_messages_max": CCIP["messages_max"]}


def main() -> int:
    path = Path(__file__).resolve().parent / "t2-limits.json"
    text = json.dumps(limits(), indent=2, sort_keys=True) + "\n"
    rows, errors = worst_case()
    if "--write" in sys.argv:
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        path.write_text(text)
        return 0
    if "--check" in sys.argv:
        ok = path.is_file() and path.read_text() == text and not errors
        print("t2-limits.json matches the schedule and fits every cap" if ok else
              "t2-limits.json differs from the schedule or a cap is exceeded", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 0 if ok else 1
    print("| chain | kind | role | planned | extra | gas max/tx | gas max total | worst native | slot |")
    print("|---|---|---|---:|---:|---:|---:|---:|---|")
    print("\n".join(r for r in rows if r.startswith("|")))
    print()
    print("\n".join(r for r in rows if not r.startswith("|")))
    print(json.dumps(counts(), indent=2))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
