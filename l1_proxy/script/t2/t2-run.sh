#!/usr/bin/env bash
# EKU-1232 T2 runner (TESTNET ONLY). One subcommand per manifest step; each wraps `script/t2/T2Route.s.sol` with the
# right chain, flags and signer. Without T2_MODE=testnet every step is a simulation (`T2_MODE=dryrun`, no
# --broadcast). With T2_MODE=testnet a step broadcasts ONLY IF T2_AUTHORIZED_SCOPE equals the approved scope id; the
# signer is an encrypted Foundry keystore ($T2_KEYSTORE_DIR/<role>.json) whose password is streamed from 1Password
# (`op read`) through a pipe. No private key or password is ever typed, printed, written in plaintext or put in argv.
#
# Usage: script/t2/t2-run.sh <step> [args...]
#   plan                         print every address the T2 keys create (read-only)
#   proxy                        Sepolia     deployer nonce 0  StarknetOwnerProxy (test instance)
#   dest <97|10143>              destination deployer nonces 0..n+1  dummy targets, Safe 2-of-3, executor
#   sender                       Sepolia     deployer nonce 1  sender (re-verifies both destinations first)
#   verify <bootstrap|proxy>     read-only route verification at VERIFY_TAG (default finalized)
#   ping <97|10143> <secs>       bootstrap request + capped dispatch (secs = deadline from now)
#   handoff                      bootstrap -> proxy, one way
#   message <cid> <nonce> <kind> <value> <deadline>   read-only: L1 message felts + Starknet call
#   l1exec  <cid> <nonce> <kind> <value> <deadline>   anyone: proxy.execute once Core recorded the message
#   dispatch <payload-hex>       anyone: capped dispatch of a Pending request
#   execute <cid> <payload-hex>  anyone: executor.execute after eta
#   canceltx <cid> <h1,h2,..>    read-only: Safe tx + safeTxHash for the two test signers
#   cancel <cid> <h1,h2,..>      Safe execTransaction with T2_SAFE_SIGNATURES (sorted by signer)
#   transfer <cid>               deployer: dummy targets -> executor after T2_PROOF_PAYLOAD executed
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${SEPOLIA_RPC_URL:?}" "${BNB_TESTNET_RPC_URL:?}" "${MONAD_TESTNET_RPC_URL:?}"
export T2_MODE="${T2_MODE:-dryrun}"
step="${1:?step}"; shift || true

rpc_for() { case "$1" in 11155111) echo "$SEPOLIA_RPC_URL";; 97) echo "$BNB_TESTNET_RPC_URL";; 10143) echo "$MONAD_TESTNET_RPC_URL";; *) echo "bad chain $1" >&2; exit 2;; esac; }
net_for() { [ "$1" = 10143 ] && echo "--network monad" || true; }

# run <chain> <signer-role|-> <sig> [args...]; roles: t2-deployer, t2-bootstrap, t2-payer (also submits the signed Safe tx)
run() {
  local cid="$1" role="$2" sig="$3" rpc; shift 3
  rpc="$(rpc_for "$cid")" || exit 2
  local flags=(--rpc-url "$rpc")
  # shellcheck disable=SC2207
  flags+=($(net_for "$cid"))
  if [ "$T2_MODE" = testnet ] && [ "$role" != - ]; then
    [ -n "${T2_APPROVED_SCOPE_ID:-}" ] && [ "${T2_AUTHORIZED_SCOPE:-}" = "$T2_APPROVED_SCOPE_ID" ] \
      || { echo "T2_AUTHORIZED_SCOPE does not match the approved scope: refusing to broadcast" >&2; exit 3; }
    local ks="${T2_KEYSTORE_DIR:?}/$role.json"
    [ -f "$ks" ] || { echo "keystore $ks missing: keys are generated only after approval" >&2; exit 3; }
    forge script script/t2/T2Route.s.sol --sig "$sig" "$@" "${flags[@]}" --broadcast --slow \
      --keystore "$ks" --password-file <(op read "op://${T2_OP_VAULT:?}/$role/password")
    return
  fi
  forge script script/t2/T2Route.s.sol --sig "$sig" "$@" "${flags[@]}"
}

case "$step" in
  plan)     run 97 - "t2Plan()" ;;
  proxy)    run 11155111 t2-deployer "t2ProxyStep()" ;;
  dest)     run "$1" t2-deployer "t2DestStep()" ;;
  sender)   if [ "$T2_MODE" = testnet ]; then run 11155111 t2-deployer "t2SenderStep()"; else run 11155111 - "t2SepoliaDryRun()"; fi ;;
  verify)   export EXPECTED_AUTHORITY
            if [ "$1" = bootstrap ]; then EXPECTED_AUTHORITY="$T2_BOOTSTRAP"; else EXPECTED_AUTHORITY="$(cast compute-address --nonce 0 "$T2_DEPLOYER" | awk '{print $NF}')"; fi
            run 11155111 - "t2VerifyRoute()" ;;
  ping)     run 11155111 t2-bootstrap "t2Ping(uint256,uint64)" "$1" "$2" ;;
  handoff)  run 11155111 t2-bootstrap "t2Handoff()" ;;
  message)  run 11155111 - "t2Message(uint256,uint64,uint8,uint256,uint64)" "$@" ;;
  l1exec)   run 11155111 t2-payer "t2L1Execute(uint256,uint64,uint8,uint256,uint64)" "$@" ;;
  dispatch) run 11155111 t2-payer "t2Dispatch(bytes)" "$1" ;;
  execute)  run "$1" t2-payer "t2Execute(bytes)" "$2" ;;
  canceltx) run "$1" - "t2CancelTx(bytes32[])" "[$2]" ;;
  cancel)   run "$1" t2-payer "t2CancelExec(bytes32[])" "[$2]" ;;
  transfer) run "$1" t2-deployer "t2TransferDummies()" ;;
  *) echo "unknown step $step" >&2; exit 2 ;;
esac
