#!/usr/bin/env bash
# EKU-1232/EKU-1261 T2 Starknet Sepolia runner (TESTNET ONLY): declare + deploy the isolated T2 voting stack
# (fixed-supply T2VotingToken -> governance Staker -> Governor at the mainnet Governor class), stake the whole test
# supply, and drive proposals whose only calls are `send_message_to_l1(T2 proxy, felts)`.
#
# Every address, class hash, constructor argument, stake amount and fee bound comes from the bound addendum and
# t2-limits.json; nothing here is an environment override. In the default T2_MODE=dryrun the exact sncast argv is
# printed and nothing is sent. With T2_MODE=testnet every transaction goes through `t2_guard.py sn --kind <kind>`:
# scope digest + approval record, exact argv shape for the kind (target, function, calldata, class hash, salt),
# Governor/Staker/token events all from the ledger, account nonce == ledger, fresh fee estimate <= per-tx max,
# cumulative fees <= 48 STRK, attempt/retry caps, durable reservation, then sncast with --max-fee/--nonce.
# The keystore password reaches sncast only via KEYSTORE_PASSWORD in its own environment (CSO L-f: acceptable for
# testnet-only keys; never reuse this for production).
#
# Usage: script/t2/t2-starknet.sh <step> [args]
#   account-deploy                deploy the t2-starknet OZ account (address bound in the addendum)
#   declare <token|staker|governor>
#   deploy <token|staker|governor>
#   stake                         approve(staker, supply) + stake_amount(self, supply)
#   propose <calls-file>          calls file = Span<Call> felts, one per line (from `t2-run.sh message`)
#   vote <id>
#   execute <p1|p2a|p2b> <id> <calls-file>
#   check                         read-only: class hashes, token supply, Staker token, Governor staker + config
set -euo pipefail
cd "$(dirname "$0")/../.."/..
: "${STARKNET_SEPOLIA_RPC_URL:?}"
T2_MODE="${T2_MODE:-dryrun}"
GUARD=(python3 l1_proxy/script/t2/t2_guard.py)
B=l1_proxy/script/t2/binding/t2-binding.json
U="$STARKNET_SEPOLIA_RPC_URL"

bound() { jq -er "$1" "$B" || { echo "binding: $1 is not bound" >&2; exit 3; }; }
send() { # kind sncast-args...
  local kind="$1"; shift
  if [ "$T2_MODE" = testnet ]; then
    "${GUARD[@]}" sn --kind "$kind" -- "$@"
  else
    printf 'DRY RUN (not sent) [%s]: sncast --keystore <t2-starknet.json> --account <t2-starknet.account.json>' "$kind"
    printf ' %q' "$@"; echo
  fi
}
felts() { grep -v '^\s*$' "$1" | tr '\n' ' '; }
cls() { bound ".starknet.classes.$1"; }

step="${1:?step}"; shift || true
case "$step" in
  account-deploy) send account-deploy account deploy --url "$U" ;;
  declare)
    c="${1:?token|staker|governor}"
    case "$c" in token) n=T2VotingToken;; staker) n=governance::staker::Staker;; governor) n=Governor;;
      *) echo "declare token|staker|governor" >&2; exit 2;; esac
    send "declare-$c" declare --url "$U" --contract-name "$n" ;;
  deploy)
    c="${1:?token|staker|governor}"
    case "$c" in
      token)    cd_=("$(bound .roles.starknet_account)") ;;
      staker)   cd_=("$(bound .starknet.token)") ;;
      governor) mapfile -t cfg < <(bound '.starknet.governor_config[]'); cd_=("$(bound .starknet.staker)" "${cfg[@]}") ;;
      *) echo "deploy token|staker|governor" >&2; exit 2 ;;
    esac
    send "deploy-$c" deploy --url "$U" --class-hash "$(cls "$c")" --salt "$(bound .starknet.salt)" --unique \
      --constructor-calldata "${cd_[@]}" ;;
  stake)
    amt="$(bound .starknet.stake_amount)"
    lo="$(python3 -c "print($amt % (1 << 128))")"; hi="$(python3 -c "print($amt >> 128)")"
    send approve invoke --url "$U" --contract-address "$(bound .starknet.token)" --function approve \
      --calldata "$(bound .starknet.staker)" "$lo" "$hi"
    send stake invoke --url "$U" --contract-address "$(bound .starknet.staker)" --function stake_amount \
      --calldata "$(bound .roles.starknet_account)" "$amt" ;;
  propose)
    # shellcheck disable=SC2046
    send propose invoke --url "$U" --contract-address "$(bound .starknet.governor)" --function propose \
      --calldata $(felts "${1:?calls file}") ;;
  vote)
    send vote invoke --url "$U" --contract-address "$(bound .starknet.governor)" --function vote --calldata "${1:?id}" 1 ;;
  execute)
    p="${1:?p1|p2a|p2b}"
    case "$p" in p1|p2a|p2b) ;; *) echo "execute p1|p2a|p2b" >&2; exit 2;; esac
    # shellcheck disable=SC2046
    send "execute-$p" invoke --url "$U" --contract-address "$(bound .starknet.governor)" --function execute \
      --calldata "${2:?id}" $(felts "${3:?calls file}") ;;
  check) "${GUARD[@]}" sn-check ;;
  *) echo "unknown step $step" >&2; exit 2 ;;
esac
