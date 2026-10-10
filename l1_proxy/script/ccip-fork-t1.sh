#!/usr/bin/env bash
# T1 read-only fork simulation of the A'-CCIP owner route (EKU-1199). Local forks only: no key, no broadcast.
# Ethereum + BNB run in one process; Monad needs `--network monad`, so it runs second and consumes the exact
# Monad payloads, message ids and addresses printed by the first run.
#
# Usage: ETH_RPC_URL=... BNB_RPC_URL=... MONAD_RPC_URL=... [ETH_FORK_BLOCK=..] [BNB_FORK_BLOCK=..] \
#        [MONAD_FORK_BLOCK=..] script/ccip-fork-t1.sh [log-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ETH_RPC_URL:?}" "${BNB_RPC_URL:?}" "${MONAD_RPC_URL:?}"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

forge test --match-contract CCIPOwnerRouteForkTest -vv | tee "$out/fork-eth-bnb.log"

val() { grep -m1 "^  $1: " "$out/fork-eth-bnb.log" | sed "s/^  $1: //"; }
export MONAD_SENDER="$(val MONAD_SENDER)"
export MONAD_EXECUTOR="$(val MONAD_EXECUTOR)"
export MONAD_PING_MSG="$(val MONAD_PING_MSG)"
export MONAD_PING_PAYLOAD="$(val MONAD_PING_PAYLOAD)"
export MONAD_OP_MSG="$(val MONAD_OP_MSG)"
export MONAD_OP_PAYLOAD="$(val MONAD_OP_PAYLOAD)"
for v in MONAD_SENDER MONAD_EXECUTOR MONAD_PING_MSG MONAD_PING_PAYLOAD MONAD_OP_MSG MONAD_OP_PAYLOAD; do
  [ -n "${!v}" ] || { echo "missing $v from the Ethereum run" >&2; exit 1; }
done

forge test --network monad --match-contract CCIPMonadForkTest -vv | tee "$out/fork-monad.log"
echo "logs in $out"
