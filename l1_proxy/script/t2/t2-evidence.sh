#!/usr/bin/env bash
# EKU-1232 T2 evidence capture (read-only). Per hop: the sender's Requested/Dispatched logs on Sepolia (tx hash,
# requestId = payloadHash, ccipMessageId, CCIP explorer link) and the executor's OWN Pinged/Queued/Cancelled/Executed
# logs on each destination (tx hash, block). OffRamp SUCCESS or explorer status is never delivery evidence; only the
# executor's own events are. Monad ranges use 100-block pages (L-7).
#
# Usage: T2_DEPLOYER=0x.. SENDER_FROM_BLOCK=.. BNB_FROM_BLOCK=.. MONAD_FROM_BLOCK=.. script/t2/t2-evidence.sh [out.md]
set -euo pipefail
: "${SEPOLIA_RPC_URL:?}" "${BNB_TESTNET_RPC_URL:?}" "${MONAD_TESTNET_RPC_URL:?}" "${T2_DEPLOYER:?}"
if [ -n "${1:-}" ]; then exec > "$1"; fi
addr() { cast compute-address --nonce "$2" "$1" | awk '{print $NF}'; }
SENDER=$(addr "$T2_DEPLOYER" 1)
E97=$(addr "$T2_DEPLOYER" 3)
E10143=$(addr "$T2_DEPLOYER" 5)

logs() { # rpc address from to chunk event
  local rpc="$1" a="$2" from="$3" to="$4" chunk="$5" ev="$6" b
  for ((b = from; b <= to; b += chunk)); do
    cast logs --rpc-url "$rpc" --address "$a" --from-block "$b" --to-block $((b + chunk - 1 > to ? to : b + chunk - 1)) \
      "$ev" --json
  done | python3 -c 'import json,sys
for line in sys.stdin.read().replace("][", "]\n[").splitlines():
    for l in json.loads(line or "[]"):
        print(int(l["blockNumber"],16), l["transactionHash"], " ".join(l["topics"][1:]))'
}

{
  echo "# T2 evidence $(date -u +%FT%TZ)"
  echo "sender $SENDER; executor 97 $E97; executor 10143 $E10143"
  echo "## Sepolia sender: Requested(requestId, destSelector, opId)"
  logs "$SEPOLIA_RPC_URL" "$SENDER" "${SENDER_FROM_BLOCK:?}" "$(cast block-number -r "$SEPOLIA_RPC_URL")" 1000 \
    "Requested(bytes32 indexed,uint64 indexed,uint64 indexed,uint8,uint32,uint64,bytes)"
  echo "## Sepolia sender: Dispatched(requestId, destSelector, ccipMessageId) -> https://ccip.chain.link/msg/<ccipMessageId>"
  logs "$SEPOLIA_RPC_URL" "$SENDER" "$SENDER_FROM_BLOCK" "$(cast block-number -r "$SEPOLIA_RPC_URL")" 1000 \
    "Dispatched(bytes32 indexed,uint64 indexed,bytes32 indexed,uint256,address)"
  echo "## Sepolia sender: HandedOff(previousAuthority, newAuthority)"
  logs "$SEPOLIA_RPC_URL" "$SENDER" "$SENDER_FROM_BLOCK" "$(cast block-number -r "$SEPOLIA_RPC_URL")" 1000 \
    "HandedOff(address indexed,address indexed)"
  for cid in 97 10143; do
    if [ "$cid" = 97 ]; then rpc=$BNB_TESTNET_RPC_URL; e=$E97; from=${BNB_FROM_BLOCK:?}; chunk=1000
    else rpc=$MONAD_TESTNET_RPC_URL; e=$E10143; from=${MONAD_FROM_BLOCK:?}; chunk=100; fi
    to=$(cast block-number -r "$rpc")
    echo "## chain $cid executor $e (own events only)"
    echo "### Pinged(payloadHash, ccipMessageId, opId)"
    logs "$rpc" "$e" "$from" "$to" "$chunk" "Pinged(bytes32 indexed,bytes32 indexed,uint64 indexed)"
    echo "### Queued(payloadHash, ccipMessageId, opId)"
    logs "$rpc" "$e" "$from" "$to" "$chunk" "Queued(bytes32 indexed,bytes32 indexed,uint64 indexed,uint64,uint64,bytes)"
    echo "### Cancelled(payloadHash, opId)"
    logs "$rpc" "$e" "$from" "$to" "$chunk" "Cancelled(bytes32 indexed,uint64 indexed)"
    echo "### Executed(payloadHash, opId)"
    logs "$rpc" "$e" "$from" "$to" "$chunk" "Executed(bytes32 indexed,uint64 indexed)"
  done
}
