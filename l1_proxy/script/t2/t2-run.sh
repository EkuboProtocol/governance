#!/usr/bin/env bash
# EKU-1232/EKU-1261 T2 runner (TESTNET ONLY). One subcommand per manifest step.
#
# Forge only SIMULATES (`forge script` without --broadcast; this runner never passes --broadcast or --resume). In the
# default `T2_MODE=dryrun` that is all that happens. With `T2_MODE=testnet` a signing step runs:
#   1. `t2_guard.py env`: recompute the scope digest from the clean tree (manifest + binding addendum + tooling) and
#      match it to the committed approval record (stage final-transactions, unexpired); export identities, Safe
#      salt, Governor felt and fee cap FROM the bound addendum (a conflicting pre-set value is refused);
#   2. a fresh simulation of the step, whose transactions become the plan;
#   3. `t2_guard.py send`: ledger reconciliation and T2 stop conditions, then per transaction: nonce, base fee and
#      cumulative caps checked, the unsigned intent and its maximum liability reserved durably in the ledger, THEN
#      signed by the step's SINGLE role keystore (`$T2_KEYSTORE_DIR/t2-<role>.json`, whose bytes must match the bound
#      evm_keystore_sha256 and are frozen before the reservation (EKU-1272 D-2); password from 1Password in a
#      memfd), every signed field compared with the reservation, the signed bytes linked durably, then published and
#      reconciled from the receipt (EKU-1268);
#   4. a read-only post-check over raw RPC.
# No private key or password is ever typed, printed, written in plaintext, put in argv or in a cast environment.
#
# Usage: script/t2/t2-run.sh <step> [args...]
#   plan                          read-only: every address the T2 keys create
#   digest | status | reconcile [--republish]    guard: scope digest (NOT an approval), ledger status, reconcile
#   proxy                         deployer  Sepolia nonce 0: StarknetOwnerProxy (test instance)
#   dest <97|10143>               deployer  destination nonces 0..n+1: dummy targets, Safe 2-of-3, executor
#   sender                        deployer  Sepolia nonce 1: sender (re-verifies both destinations first)
#   verify <bootstrap|proxy>      read-only route verification at VERIFY_TAG (default finalized)
#   ping-request <97|10143> <secs>   bootstrap  ping request ONLY (prints the payload; nothing crosses CCIP)
#   dispatch <payload-hex>        payer     capped dispatch of a Pending request (pings and Governor requests)
#   handoff                       bootstrap one-way handoff to the proxy
#   message <cid> <nonce> <kind> <value> <deadline>   read-only: L1 message felts + Starknet call
#   l1exec  <cid> <nonce> <kind> <value> <deadline>   payer: proxy.execute once Core recorded the message
#   execute <cid> <payload-hex>   payer     executor.execute after eta
#   canceltx <cid> <h1,h2,..>     read-only: Safe tx + safeTxHash for the two test signers
#   cancel <cid> <h1,h2,..>       payer     Safe execTransaction with T2_SAFE_SIGNATURES (sorted by signer)
#   transfer <cid>                deployer  dummy targets -> executor after T2_PROOF_PAYLOAD executed
#   manualexec <cid> <calldata-file>  payer  OffRamp 2.0.0 execute(...) built by CCIP tooling (hex in the file)
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${SEPOLIA_RPC_URL:?}" "${BNB_TESTNET_RPC_URL:?}" "${MONAD_TESTNET_RPC_URL:?}"
export T2_MODE="${T2_MODE:-dryrun}"
case "$T2_MODE" in testnet|dryrun) ;; *) echo "T2_MODE must be testnet or dryrun" >&2; exit 2 ;; esac
GUARD=(python3 script/t2/t2_guard.py)
step="${1:?step}"; shift || true

rpc_for() { case "$1" in 11155111) echo "$SEPOLIA_RPC_URL";; 97) echo "$BNB_TESTNET_RPC_URL";; 10143) echo "$MONAD_TESTNET_RPC_URL";; *) echo "bad chain $1" >&2; return 2;; esac; }
net_for() { [ "$1" = 10143 ] && echo "--network monad" || true; }

# sim <chain> <sig> [args...]: simulation only; prints the dry-run transaction file it produced (empty if none).
sim() {
  local cid="$1" sig="$2" rpc fn json; shift 2
  rpc="$(rpc_for "$cid")"
  fn="${sig%%(*}"
  json="broadcast/T2Route.s.sol/$cid/dry-run/$fn-latest.json"
  rm -f "$json"
  # shellcheck disable=SC2046
  forge script script/t2/T2Route.s.sol --sig "$sig" "$@" --rpc-url "$rpc" $(net_for "$cid") >&2
  [ -f "$json" ] && echo "$json" || true
}

# signing step: sign <guard-step> <role> <chain> <sig> [args...]
sign() {
  local gstep="$1" role="$2" cid="$3" sig="$4" plan; shift 4
  if [ "$T2_MODE" != testnet ]; then
    sim "$cid" "$sig" "$@" >/dev/null
    echo "DRY RUN: simulated only, nothing signed or sent" >&2
    return
  fi
  local envs
  envs="$("${GUARD[@]}" env)" || { echo "scope not authorized: refusing before any simulation or signing" >&2; exit 3; }
  eval "$envs"
  "${GUARD[@]}" preflight || exit 3
  plan="$(sim "$cid" "$sig" "$@")"
  [ -n "$plan" ] || { echo "simulation produced no transactions: refusing" >&2; exit 3; }
  "${GUARD[@]}" send --step "$gstep" --chain "$cid" --role "$role" --plan "$plan"
}

readonly_step() { # read-only forge call, bound env exported in testnet mode
  local cid="$1" sig="$2"; shift 2
  if [ "$T2_MODE" = testnet ]; then
    local envs; envs="$("${GUARD[@]}" env)" || exit 3; eval "$envs"
  fi
  # shellcheck disable=SC2046
  forge script script/t2/T2Route.s.sol --sig "$sig" "$@" --rpc-url "$(rpc_for "$cid")" $(net_for "$cid")
}

post() { [ "$T2_MODE" = testnet ] && readonly_step "$@" || true; }

case "$step" in
  plan)       readonly_step 97 "t2Plan()" ;;
  digest)     "${GUARD[@]}" digest ;;
  status)     "${GUARD[@]}" status ;;
  reconcile)  "${GUARD[@]}" reconcile "$@" ;;
  proxy)      sign proxy deployer 11155111 "t2ProxyStep()"; post 11155111 "t2CheckProxy()" ;;
  dest)       sign dest deployer "$1" "t2DestStep()"; post "$1" "t2CheckDest(uint256)" "$1" ;;
  sender)     if [ "$T2_MODE" = testnet ]; then sign sender deployer 11155111 "t2SenderStep()"; post 11155111 "t2CheckSender()"
              else sim 11155111 "t2SepoliaDryRun()" >/dev/null; fi ;;
  verify)     export EXPECTED_AUTHORITY
              if [ "$1" = bootstrap ]; then EXPECTED_AUTHORITY="${T2_BOOTSTRAP:?}"; else EXPECTED_AUTHORITY="$(cast compute-address --nonce 0 "${T2_DEPLOYER:?}" | awk '{print $NF}')"; fi
              readonly_step 11155111 "t2VerifyRoute()" ;;
  ping)       echo "ping is split (T2-1): ping-request <cid> <secs> (bootstrap), then dispatch <payload> (payer)" >&2; exit 2 ;;
  ping-request) sign ping-request bootstrap 11155111 "t2PingRequest(uint256,uint64)" "$1" "$2" ;;
  dispatch)   sign dispatch payer 11155111 "t2Dispatch(bytes)" "$1" ;;
  handoff)    sign handoff bootstrap 11155111 "t2Handoff()" ;;
  message)    readonly_step 11155111 "t2Message(uint256,uint64,uint8,uint256,uint64)" "$@" ;;
  l1exec)     sign l1exec payer 11155111 "t2L1Execute(uint256,uint64,uint8,uint256,uint64)" "$@" ;;
  execute)    sign execute payer "$1" "t2Execute(bytes)" "$2" ;;
  canceltx)   readonly_step "$1" "t2CancelTx(bytes32[])" "[$2]" ;;
  cancel)     sign cancel payer "$1" "t2CancelExec(bytes32[])" "[$2]" ;;
  transfer)   sign transfer deployer "$1" "t2TransferDummies()" ;;
  manualexec)
    cid="$1"; data="$(tr -d ' \n' < "${2:?calldata file}")"
    case "$cid" in 97) ramp=0x32d4DD31a03e82FE7B1b8C9E5E6fa028B2fcA770;; 10143) ramp=0x8C7676A0E7289Fe1ECb09d77a755E52AFd5eC471;; *) echo "manualexec: 97 or 10143" >&2; exit 2;; esac
    [ "$T2_MODE" = testnet ] || { echo "DRY RUN: manualexec to $ramp, $(( (${#data} - 2) / 2 )) calldata bytes; nothing signed" >&2; exit 0; }
    envs="$("${GUARD[@]}" env)" || exit 3; eval "$envs"
    rpc="$(rpc_for "$cid")"
    gas="$(cast estimate --rpc-url "$rpc" --from "$T2_PAYER" "$ramp" "$data")"
    plan="$(mktemp)"; trap 'rm -f "$plan"' EXIT
    jq -n --arg from "$T2_PAYER" --arg to "$ramp" --arg input "$data" --argjson cid "$cid" \
      --arg nonce "$(printf '0x%x' "$(cast nonce --rpc-url "$rpc" "$T2_PAYER")")" --arg gas "$(printf '0x%x' $(( gas * 13 / 10 )))" \
      '{chain:$cid, transactions:[{transactionType:"CALL", transaction:{from:$from,to:$to,value:"0x0",input:$input,nonce:$nonce,gas:$gas,chainId:("0x"+($cid|tostring|tonumber|tostring))}}]}' \
      | jq --arg c "$(printf '0x%x' "$cid")" '.transactions[0].transaction.chainId=$c' > "$plan"
    "${GUARD[@]}" send --step manualexec --chain "$cid" --role payer --plan "$plan" ;;
  *) echo "unknown step $step" >&2; exit 2 ;;
esac
