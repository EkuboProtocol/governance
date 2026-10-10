#!/usr/bin/env bash
# EKU-1232 T2 Starknet Sepolia runner (TESTNET ONLY): declare + deploy the short-period Governor stack, stake, and
# drive proposals whose calls are `send_message_to_l1(T2 proxy, felts)`. Repository root is the Scarb package.
#
# Default (T2_MODE unset or dryrun): prints the exact sncast command and runs `declare --dry-run`-style checks only
# where sncast supports them; nothing is sent. With T2_MODE=testnet and T2_AUTHORIZED_SCOPE == T2_APPROVED_SCOPE_ID it
# sends from the encrypted keystore account ($T2_KEYSTORE_DIR/t2-starknet.json + t2-starknet.account.json); the
# keystore password is read from 1Password into KEYSTORE_PASSWORD for the sncast process only.
#
# Usage: script/t2/t2-starknet.sh <step> [args]
#   declare                      declare governance::staker::Staker and Governor (class hashes pinned below)
#   deploy-staker                Staker(token = STRK)            salt 0x1232, not unique
#   deploy-governor <staker>     Governor(staker, T2 config)     salt 0x1232, not unique
#   stake <staker>               approve + stake_amount(self, T2_STAKE)
#   propose <governor> <file>    file = serialized Span<Call> felts (one per line; from `t2-run.sh message`)
#   vote <governor> <id>
#   execute <governor> <id> <file>
#   check <governor> <staker>    read-only: class hashes, get_config, get_staker
set -euo pipefail
cd "$(dirname "$0")/../.."/..
: "${STARKNET_SEPOLIA_RPC_URL:?}"
T2_MODE="${T2_MODE:-dryrun}"
STRK=0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
GOVERNOR_CLASS=0x044e2e3d2ae1b0415450b2b5d417698ce495f7ef500826ddb48a61f9dfe67401 # == mainnet Governor class
STAKER_CLASS=0x0244c2213a85dc27cb4f966a6ce48be0b7d38aafad6882ca063a2da97f09dade   # governance::staker::Staker
SALT=0x1232
T2_STAKE="${T2_STAKE:-2000000000000000000}" # 2 STRK, withdrawable
# Config: voting_start_delay 60, voting_period 600, smoothing 60, quorum 1e18, threshold 1e18, exec delay 60, window 7 d
CONFIG="60 600 60 1000000000000000000 1000000000000000000 60 604800"

sn() {
  if [ "$T2_MODE" = testnet ]; then
    [ -n "${T2_APPROVED_SCOPE_ID:-}" ] && [ "${T2_AUTHORIZED_SCOPE:-}" = "$T2_APPROVED_SCOPE_ID" ] \
      || { echo "T2_AUTHORIZED_SCOPE does not match the approved scope: refusing" >&2; exit 3; }
    KEYSTORE_PASSWORD="$(op read "op://${T2_OP_VAULT:?}/t2-starknet/password")" \
      sncast --keystore "${T2_KEYSTORE_DIR:?}/t2-starknet.json" --account "$T2_KEYSTORE_DIR/t2-starknet.account.json" \
      --wait "$@"
  else
    printf 'DRY RUN (not sent): sncast --keystore <t2-starknet.json> --account <t2-starknet.account.json> --wait'
    printf ' %q' "$@"; echo
  fi
}
call() { sncast call --url "$STARKNET_SEPOLIA_RPC_URL" "$@"; }
felts() { tr '\n' ' ' < "$1"; }

step="${1:?step}"; shift || true
case "$step" in
  declare)
    scarb --release build
    for c in governance::staker::Staker Governor; do
      sncast utils class-hash --contract-name "$c" --scarb-profile release
      sn --scarb-profile release declare --url "$STARKNET_SEPOLIA_RPC_URL" --contract-name "$c"
    done ;;
  deploy-staker)
    sn deploy --url "$STARKNET_SEPOLIA_RPC_URL" --class-hash "$STAKER_CLASS" --salt "$SALT" \
      --constructor-calldata "$STRK" ;;
  deploy-governor)
    # shellcheck disable=SC2086
    sn deploy --url "$STARKNET_SEPOLIA_RPC_URL" --class-hash "$GOVERNOR_CLASS" --salt "$SALT" \
      --constructor-calldata "${1:?staker}" $CONFIG ;;
  stake)
    sn invoke --url "$STARKNET_SEPOLIA_RPC_URL" --contract-address "$STRK" --function approve \
      --calldata "${1:?staker}" "$T2_STAKE" 0
    sn invoke --url "$STARKNET_SEPOLIA_RPC_URL" --contract-address "$1" --function stake_amount \
      --calldata "${T2_STARKNET_ACCOUNT:?}" "$T2_STAKE" ;;
  propose)
    # shellcheck disable=SC2046
    sn invoke --url "$STARKNET_SEPOLIA_RPC_URL" --contract-address "${1:?governor}" --function propose \
      --calldata $(felts "${2:?calls file}") ;;
  vote)
    sn invoke --url "$STARKNET_SEPOLIA_RPC_URL" --contract-address "${1:?governor}" --function vote \
      --calldata "${2:?id}" 1 ;;
  execute)
    # shellcheck disable=SC2046
    sn invoke --url "$STARKNET_SEPOLIA_RPC_URL" --contract-address "${1:?governor}" --function execute \
      --calldata "${2:?id}" $(felts "${3:?calls file}") ;;
  check)
    for a in "${1:?governor}" "${2:?staker}"; do
      curl -sS -H 'content-type: application/json' --data \
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"starknet_getClassHashAt\",\"params\":[\"latest\",\"$a\"]}" \
        "$STARKNET_SEPOLIA_RPC_URL"; echo
    done
    call --contract-address "$1" --function get_config
    call --contract-address "$1" --function get_staker ;;
  *) echo "unknown step $step" >&2; exit 2 ;;
esac
