#!/usr/bin/env bash
# EKU-1261 LOCAL fail-closed end-to-end test of the T2 signing path: t2-run.sh -> forge simulation -> t2_guard.py
# (scope digest + approval record, ledger, caps, cast mktx with one role keystore, signed-field verification,
# publish, receipt) against three LOCAL anvil forks of Ethereum Sepolia, BNB Chain testnet and Monad testnet.
#
# Nothing here touches a live network: anvil forks read public RPCs and keep all writes local. The six EVM keys are
# THROWAWAY keys generated in the work directory for this run only; they are never funded on any network (their
# local balances come from anvil_setBalance) and are deleted with the directory. 1Password is replaced by a
# test-only `op` shim reading the throwaway passwords. The approval record is a LOCAL TEST record in a throwaway
# clone; it authorizes nothing anywhere else.
#
# Usage: SEPOLIA_FORK_URL=.. BNB_TESTNET_FORK_URL=.. MONAD_TESTNET_FORK_URL=.. STARKNET_SEPOLIA_RPC_URL=.. \
#        l1_proxy/script/t2/test/t2-local-e2e.sh [work-dir]
set -euo pipefail
SRC="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
W="${1:-$(mktemp -d)}"
mkdir -p "$W"
W="$(cd "$W" && pwd)"
: "${SEPOLIA_FORK_URL:?}" "${BNB_TESTNET_FORK_URL:?}" "${MONAD_TESTNET_FORK_URL:?}" "${STARKNET_SEPOLIA_RPC_URL:?}"
PASS=0
log() { printf '\n=== %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- local chains
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
start() { # url chain port [extra]
  anvil --fork-url "$1" --chain-id "$2" --port "$3" ${4:-} --silent > "$W/anvil-$2.log" 2>&1 &
  pids+=("$!")
}
start "$SEPOLIA_FORK_URL" 11155111 18545 "${SEPOLIA_FORK_BLOCK:+--fork-block-number $SEPOLIA_FORK_BLOCK}"
start "$BNB_TESTNET_FORK_URL" 97 18546
start "$MONAD_TESTNET_FORK_URL" 10143 18547
export SEPOLIA_RPC_URL=http://127.0.0.1:18545 BNB_TESTNET_RPC_URL=http://127.0.0.1:18546 MONAD_TESTNET_RPC_URL=http://127.0.0.1:18547
for u in "$SEPOLIA_RPC_URL" "$BNB_TESTNET_RPC_URL" "$MONAD_TESTNET_RPC_URL"; do
  for _ in $(seq 60); do cast chain-id -r "$u" >/dev/null 2>&1 && break; sleep 1; done
  cast chain-id -r "$u" >/dev/null || die "anvil at $u did not start"
done

# ---------------------------------------------------------------- throwaway keys, op shim, local funds
mkdir -p "$W/ks" "$W/pw" "$W/bin"
chmod 700 "$W/ks" "$W/pw"
declare -A ADDR
for r in deployer bootstrap payer safe-signer-a safe-signer-b safe-signer-c; do
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$W/pw/t2-$r"
  ADDR[$r]="$(CAST_PASSWORD="$(cat "$W/pw/t2-$r")" cast wallet new "$W/ks" "t2-$r.json" 2>&1 | awk '/^Address:/{print $2}')"
  [ -n "${ADDR[$r]}" ] || die "no address for $r"
done
cat > "$W/bin/op" <<EOF
#!/bin/sh
# TEST-ONLY 1Password shim: op read op://<vault>/<item>/password
[ "\$1" = read ] || exit 2
item=\$(printf '%s' "\$2" | cut -d/ -f4)
cat "$W/pw/\$item"
EOF
chmod +x "$W/bin/op"
export PATH="$W/bin:$PATH"
fund() { cast rpc -r "$1" anvil_setBalance "$2" "$(printf '0x%x' "$3")" >/dev/null; }
fund "$SEPOLIA_RPC_URL" "${ADDR[deployer]}" 60000000000000000
fund "$SEPOLIA_RPC_URL" "${ADDR[bootstrap]}" 10000000000000000
fund "$SEPOLIA_RPC_URL" "${ADDR[payer]}" 180000000000000000
fund "$BNB_TESTNET_RPC_URL" "${ADDR[deployer]}" 30000000000000000
fund "$BNB_TESTNET_RPC_URL" "${ADDR[payer]}" 20000000000000000
fund "$MONAD_TESTNET_RPC_URL" "${ADDR[deployer]}" 1400000000000000000
fund "$MONAD_TESTNET_RPC_URL" "${ADDR[payer]}" 600000000000000000

# ---------------------------------------------------------------- throwaway clone at the tested head
R="$W/repo"
git clone -q --no-hardlinks "$SRC" "$R"
git -C "$R" checkout -q --detach "$(git -C "$SRC" rev-parse HEAD)"
for m in forge-std solady; do
  git -C "$R" config "submodule.l1_proxy/lib/$m.url" "$SRC/l1_proxy/lib/$m"
done
git -C "$R" -c protocol.file.allow=always submodule update --init -q
git -C "$R" config user.name "t2-local-e2e"
git -C "$R" config user.email "t2-local-e2e@invalid"
T2="$R/l1_proxy/script/t2"
SNACCT="0x0$(head -c 31 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-62)"
felt() { printf '0x0%s' "$(head -c 31 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-62)"; }
# Starknet identity: LOCAL TEST public values only (this e2e sends nothing on Starknet; no Starknet key exists).
head -c 64 /dev/urandom > "$W/sn-keystore-placeholder"
jq -n --arg d "${ADDR[deployer]}" --arg b "${ADDR[bootstrap]}" --arg p "${ADDR[payer]}" \
  --arg a "${ADDR[safe-signer-a]}" --arg bb "${ADDR[safe-signer-b]}" --arg c "${ADDR[safe-signer-c]}" --arg s "$SNACCT" \
  --arg pk "$(felt)" --arg ch "$(felt)" --arg salt "$(felt)" --arg ks "$(sha256sum "$W/sn-keystore-placeholder" | cut -d' ' -f1)" \
  --arg ld "$W/ledger" \
  '{deployer:$d, bootstrap:$b, payer:$p, safe_owners:[$a,$bb,$c], starknet_account:$s, op_vault:"local-e2e",
    ledger_dir:$ld, starknet_public_key:$pk, starknet_account_class_hash:$ch, starknet_account_salt:$salt,
    starknet_keystore_sha256:$ks,
    faucet_sources:[["eip155:11155111"],["eip155:97"],["eip155:10143"],["starknet:SN_SEPOLIA"]] | map({chain:.[0],
      source:"LOCAL TEST fixture", url:"https://faucet.invalid/", eligibility:"LOCAL TEST ONLY: no faucet is used",
      eligibility_checked_at:"2026-10-10T00:00:00Z", drip_max:"1", login:"none", region:"none",
      operator:"LOCAL TEST (no human, no request)", automated_allowed:false, paid:false, mainnet_prerequisite:false})}' \
  > "$W/keys.json"
python3 "$T2/t2_guard.py" bind --keys "$W/keys.json"
git -C "$R" commit -q -am "LOCAL TEST binding (throwaway keys)"

approve() { # stage approved_at expires_at
  local d; d="$(python3 "$T2/t2_guard.py" digest 2>/dev/null)"
  jq -n --argjson d "$d" --arg st "$1" --arg t0 "$2" --arg t1 "$3" \
    '{schema:"ekubo-t2-approval-v1", stage:$st, scope_digest:$d.scope_digest, manifest_sha256:$d.manifest_sha256,
      binding_sha256:$d.binding_sha256, tooling_sha256:$d.tooling_sha256, approved_by:"LOCAL TEST ONLY",
      approval_ref:"t2-local-e2e", approved_at:$t0, expires_at:$t1}' > "$T2/binding/t2-approval.json"
  git -C "$R" add -A && git -C "$R" commit -q -m "LOCAL TEST approval record ($1)"
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LATER="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"

export T2_KEYSTORE_DIR="$W/ks" T2_OP_VAULT=local-e2e T2_LEDGER_DIR="$W/ledger" T2_RECEIPT_TIMEOUT=60
run() { (cd "$R/l1_proxy" && T2_MODE=testnet script/t2/t2-run.sh "$@") > "$W/last.log" 2>&1; }
expect_ok() { run "$@" || { tail -40 "$W/last.log"; die "$*"; }; }
expect_refused() { # pattern step...
  local pat="$1"; shift
  if run "$@"; then tail -20 "$W/last.log"; die "expected refusal: $*"; fi
  grep -q -- "$pat" "$W/last.log" || { tail -20 "$W/last.log"; die "refused for another reason (want '$pat'): $*"; }
}
nonce() { cast nonce -r "$1" "$2"; }

log "scope gate (T2-3)"
expect_refused "no approval record" proxy && ok "no approval record: refused before simulation"
approve key-preparation "$NOW" "$LATER"
expect_refused "does not authorize transactions" proxy && ok "key-preparation record never authorizes transactions"
approve final-transactions "$(date -u -d '-3 days' +%FT%TZ)" "$(date -u -d '-1 day' +%FT%TZ)"
expect_refused "approval not valid now" proxy && ok "expired approval refused"
approve final-transactions "$NOW" "$(date -u -d '+15 days' +%FT%TZ)"
expect_refused "longer than 14 days" proxy && ok "approval window > 14 days refused"
approve final-transactions "$NOW" "$LATER"
[ "$(nonce "$SEPOLIA_RPC_URL" "${ADDR[deployer]}")" = 0 ] || die "a refused step sent something"
ok "deployer nonce still 0 after every refusal"

log "deployment through the guard (deployer keystore only)"
expect_ok proxy && ok "proxy (Sepolia nonce 0) + post-check"
expect_ok dest 97 && ok "dest 97 (targets, Safe, executor) + post-check"
expect_ok dest 10143 && ok "dest 10143 + post-check"
expect_ok sender && ok "sender (Sepolia nonce 1) + post-check"

log "binding and override refusals"
printf ' ' >> "$T2/binding/t2-binding.json"
expect_refused "differ from the committed tree" ping-request 97 259200 && ok "one changed byte (uncommitted) refused"
git -C "$R" checkout -q -- l1_proxy/script/t2/binding/t2-binding.json
T2_PAYER="${ADDR[bootstrap]}" expect_refused "differs from the bound addendum" dispatch 0x00 \
  && ok "pre-set T2_PAYER override refused"
T2_MAX_FEE_WEI=3000000000000000 expect_refused "differs from the bound addendum" dispatch 0x00 \
  && ok "raised T2_MAX_FEE_WEI override refused"

log "two-role ping (T2-1/F3)"
mkdir -p "$W/ks-swap" && cp "$W/ks/t2-payer.json" "$W/ks-swap/t2-bootstrap.json"
cp "$W/pw/t2-payer" "$W/pw/t2-bootstrap.swap"
b0="$(nonce "$SEPOLIA_RPC_URL" "${ADDR[bootstrap]}")"; p0="$(nonce "$SEPOLIA_RPC_URL" "${ADDR[payer]}")"
mv "$W/pw/t2-bootstrap" "$W/pw/t2-bootstrap.real" && mv "$W/pw/t2-bootstrap.swap" "$W/pw/t2-bootstrap"
T2_KEYSTORE_DIR="$W/ks-swap" expect_refused "signed transaction field signer" ping-request 97 259200
mv "$W/pw/t2-bootstrap.real" "$W/pw/t2-bootstrap"
[ "$(nonce "$SEPOLIA_RPC_URL" "${ADDR[bootstrap]}")" = "$b0" ] && [ "$(nonce "$SEPOLIA_RPC_URL" "${ADDR[payer]}")" = "$p0" ] \
  || die "mismatched keystore published something"
ok "payer keystore under the bootstrap role: signed bytes refused, nothing published"
grep -q '"type":"void"' "$W"/ledger/ledger-*.jsonl && grep -q 'never published' "$W"/ledger/ledger-*.jsonl \
  || die "the refused signing attempt was not reserved and closed as void"
ok "that attempt was reserved before signing and closed as void (attempt still counted)"

python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)' \
  "$W/ledger/$(ls "$W/ledger" | grep '\.lock$')" & lockpid=$!
sleep 1
expect_refused "locked by another T2 runner" ping-request 97 259200 && ok "concurrent runner refused"
kill "$lockpid" 2>/dev/null || true; wait "$lockpid" 2>/dev/null || true

cast rpc -r "$SEPOLIA_RPC_URL" anvil_setNextBlockBaseFeePerGas 0x5d21dba00 >/dev/null
cast rpc -r "$SEPOLIA_RPC_URL" evm_mine >/dev/null
expect_refused "above the gas-price ceiling" ping-request 97 259200 && ok "base fee 25 gwei > 20 gwei ceiling refused"
cast rpc -r "$SEPOLIA_RPC_URL" anvil_setNextBlockBaseFeePerGas 0x3b9aca00 >/dev/null
cast rpc -r "$SEPOLIA_RPC_URL" evm_mine >/dev/null

payload_of() { awk '/ping requested \(NOT dispatched\)/{getline; getline; print $1; exit}' "$W/last.log"; }
expect_ok ping-request 97 259200 && ok "bootstrap ping request (bootstrap keystore only)"
P97="$(payload_of)"; [ -n "$P97" ] || die "no ping payload"
[ "$(nonce "$SEPOLIA_RPC_URL" "${ADDR[payer]}")" = "$p0" ] || die "ping-request used the payer"
expect_ok dispatch "$P97" && ok "payer dispatch of the bootstrap request (payer keystore only)"
grep -q "sent dispatch" "$W/last.log" || die "no dispatch"

log "crash, restart and reconciliation (F1)"
if T2_FAULT=linked run ping-request 10143 259200; then die "fault hook did not fire"; fi
P10143="$(payload_of)"
expect_refused "unknown outcome" dispatch "$P10143" && ok "after a crash between the durable signed link and publish: next attempt refused"
(cd "$R/l1_proxy" && T2_MODE=testnet script/t2/t2-run.sh reconcile --republish) > "$W/last.log" 2>&1 || { cat "$W/last.log"; die reconcile; }
grep -q "republished reserved tx" "$W/last.log" && ok "reconcile republished the identical signed bytes (no new liability)"
expect_ok dispatch "$P10143" && ok "dispatch after reconciliation"

log "ledger loss and out-of-band transactions fail closed"
mv "$W/ledger" "$W/ledger.bak"
expect_refused "deleted ledger, manual transaction or lost receipt" handoff && ok "deleted ledger refused (nonces > ledger)"
rm -rf "$W/ledger" && mv "$W/ledger.bak" "$W/ledger"
expect_ok handoff && ok "handoff (bootstrap)"
expect_refused "authority is not the bootstrap key" ping-request 97 259200 && ok "bootstrap request after handoff refused in simulation"
(cd "$R/l1_proxy" && T2_MODE=testnet script/t2/t2-run.sh status) > "$W/status.log" 2>&1
cat "$W/status.log"
python3 - "$W"/ledger/ledger-*.jsonl <<'PY' || die "ledger order: a signature without an earlier reservation"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
evm = [r for r in recs if r["type"] == "reserve" and r["chain"] != "SN_SEPOLIA"]
assert evm and all(r["hash"] == "" for r in evm), "EVM reservation written with a hash (sign-then-reserve)"
for r in recs:
    if r["type"] == "signed":
        res = recs[r["ref"]]
        assert res["type"] == "reserve" and res["seq"] < r["seq"], r
print(f"ledger order OK: {len(evm)} EVM reservations, each before its signed link")
PY
ok "real ledger: every EVM reservation precedes its signature link (no sign-then-reserve)"
cast send -q -r "$SEPOLIA_RPC_URL" --keystore "$W/ks/t2-payer.json" --password-file "$W/pw/t2-payer" \
  "${ADDR[payer]}" --value 1 >/dev/null
expect_refused "deleted ledger, manual transaction or lost receipt" dispatch "$P97" && ok "out-of-band payer transaction refused"

log "committed scope change without a new approval"
python3 - "$T2/binding/t2-binding.json" <<'EOF'
import json, sys
p = sys.argv[1]; b = json.load(open(p)); b["note"] += " (edited)"; open(p, "w").write(json.dumps(b, indent=2) + "\n")
EOF
git -C "$R" commit -q -am "LOCAL TEST: binding edited after approval"
expect_refused "approval binding_sha256" dispatch "$P97" && ok "binding changed after approval refused"

printf '\n%d checks PASSED; work dir %s\n' "$PASS" "$W"
