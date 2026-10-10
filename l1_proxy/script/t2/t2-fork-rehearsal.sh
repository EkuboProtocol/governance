#!/usr/bin/env bash
# EKU-1232 local fork REHEARSAL of the T2 testnet pack. Local forks only: public fixture keys, no broadcast, no funds.
# Sepolia + BNB Chain testnet run in one process; Monad testnet needs `--network monad`, so it runs second and consumes
# the exact payloads, message ids and addresses printed by the first run.
#
# Usage: SEPOLIA_RPC_URL=... BNB_TESTNET_RPC_URL=... MONAD_TESTNET_RPC_URL=... [SEPOLIA_FORK_BLOCK=..] \
#        [BNB_TESTNET_FORK_BLOCK=..] [MONAD_TESTNET_FORK_BLOCK=..] script/t2/t2-fork-rehearsal.sh [log-dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${SEPOLIA_RPC_URL:?}" "${BNB_TESTNET_RPC_URL:?}" "${MONAD_TESTNET_RPC_URL:?}"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

forge test --match-contract T2RehearsalForkTest -vv | tee "$out/t2-fork-sepolia-bnbtestnet.log"

val() { grep -m1 "^  $1: " "$out/t2-fork-sepolia-bnbtestnet.log" | sed "s/^  $1: //"; }
vars="MONAD_T2_SENDER MONAD_T2_EXECUTOR MONAD_T2_PING_MSG MONAD_T2_PING_PAYLOAD MONAD_T2_PROOF_MSG MONAD_T2_PROOF_PAYLOAD MONAD_T2_SET_MSG MONAD_T2_SET_PAYLOAD"
for v in $vars; do
  export "$v=$(val "$v")"
  [ -n "${!v}" ] || { echo "missing $v from the Sepolia run" >&2; exit 1; }
done

forge test --network monad --match-contract T2MonadRehearsalForkTest -vv | tee "$out/t2-fork-monadtestnet.log"
echo "logs in $out"
