#!/usr/bin/env bash
# Checks that wave4-l1-calldata.sh enforces created + 352800 < FX_DEADLINE <= created + 352800 + 14 days.
# No RPC needed. Usage: ./script/wave4-l1-calldata.test.sh
set -uo pipefail
cd "$(dirname "$0")"

C=1790000000
E=$((C + 352800))
M=$((E + 14 * 86400))
failures=0

run() { # expect(pass|fail) created deadline label
  local out rc
  out=$(PROPOSAL_CREATED=$2 FX_DEADLINE=$3 DEADLINE_CHECK_ONLY=1 ./wave4-l1-calldata.sh 2>&1)
  rc=$?
  if { [[ $1 == pass ]] && ((rc == 0)); } || { [[ $1 == fail ]] && ((rc != 0)); }; then
    echo "ok   $1: $4"
  else
    echo "FAIL expected $1 (rc=$rc): $4: $out"
    failures=$((failures + 1))
  fi
}

run fail "$C" "$C" "deadline = created"
run fail "$C" "$E" "deadline = earliest relay (lower bound is strict)"
run pass "$C" "$((E + 1))" "deadline = earliest relay + 1s"
run pass "$C" "$((E + 7 * 86400))" "deadline = earliest relay + 7 days"
run pass "$C" "$M" "deadline = earliest relay + 14 days (upper bound inclusive)"
run fail "$C" "$((M + 1))" "deadline = earliest relay + 14 days + 1s"
run fail "$C" "$((M + 365 * 86400))" "deadline a year too late"
run fail "" "$((E + 1))" "missing PROPOSAL_CREATED"
run fail "$C" "" "missing FX_DEADLINE"
run fail "$C" "0x$(printf %x $((E + 1)))" "hex deadline rejected"
run fail "-5" "$((E + 1))" "negative created rejected"

run_env() { # expect(pass|fail) label env...
  local expect=$1 label=$2 out rc
  shift 2
  out=$(env PROPOSAL_CREATED="$C" FX_DEADLINE="$((E + 1))" DEADLINE_CHECK_ONLY=1 "$@" ./wave4-l1-calldata.sh 2>&1)
  rc=$?
  if { [[ $expect == pass ]] && ((rc == 0)); } || { [[ $expect == fail ]] && ((rc != 0)); }; then
    echo "ok   $expect: $label"
  else
    echo "FAIL expected $expect (rc=$rc): $label: $out"
    failures=$((failures + 1))
  fi
}

run_env pass "ACTION=reach accepted" ACTION=reach
run_env pass "ACTION=handover accepted" ACTION=handover
run_env fail "unknown ACTION rejected" ACTION=transfer
run_env pass "NONCE_OFFSET=8 accepted" ACTION=reach NONCE_OFFSET=8
run_env fail "negative NONCE_OFFSET rejected" NONCE_OFFSET=-1
run_env fail "hex NONCE_OFFSET rejected" NONCE_OFFSET=0x8

if ((failures)); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all deadline checks passed"
