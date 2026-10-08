#!/usr/bin/env bash
# Builds the Ethereum-side call for one Governor message per chain (Gnosis AMB, Polygon FxPortal) and checks it
# against live Ethereum state. Prints the target, value and data that StarknetOwnerProxy.execute must be called
# with, plus the inner batch and a gas estimate from the L1 proxy.
#
# Usage:
#   GNOSIS_PROXY=0x... POLYGON_PROXY=0x... FX_DEADLINE=<unix seconds> ACTION=handover|<custom> \
#     ETH_RPC_URL=... ./script/wave4-l1-calldata.sh
#
# ACTION=handover (default) builds [Positions.requestOwnershipHandover(), Orders.requestOwnershipHandover()].
# FX_DEADLINE must be no more than 14 days after the earliest time the L1 message can be relayed.
set -euo pipefail

: "${GNOSIS_PROXY:?}" "${POLYGON_PROXY:?}" "${FX_DEADLINE:?}" "${ETH_RPC_URL:?}"
ACTION="${ACTION:-handover}"

L1_PROXY=0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc
FOREIGN_AMB=0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e
FX_ROOT=0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2
AMB_GAS=500000
POSITIONS=0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326
ORDERS=0x9bB520B6192F71ec3D015C8a74F914f9c94bF794
CALL_T='(address,uint256,bytes)[]'

if [[ "$ACTION" != handover ]]; then
  echo "only ACTION=handover is implemented" >&2
  exit 1
fi
REQ=$(cast calldata 'requestOwnershipHandover()')
CALLS="[($POSITIONS,0,$REQ),($ORDERS,0,$REQ)]"

AMB_INNER=$(cast calldata "executeBatch($CALL_T)" "$CALLS")
AMB_DATA=$(cast calldata 'requireToPassMessage(address,bytes,uint256)' "$GNOSIS_PROXY" "$AMB_INNER" "$AMB_GAS")

FX_MESSAGE=$(cast abi-encode "f($CALL_T,uint64)" "$CALLS" "$FX_DEADLINE")
FX_DATA=$(cast calldata 'sendMessageToChild(address,bytes)' "$POLYGON_PROXY" "$FX_MESSAGE")

BN=$(cast block-number --rpc-url "$ETH_RPC_URL")
BH=$(cast block "$BN" -f hash --rpc-url "$ETH_RPC_URL")
BT=$(cast block "$BN" -f timestamp --rpc-url "$ETH_RPC_URL")
BF=$(cast block "$BN" -f baseFeePerGas --rpc-url "$ETH_RPC_URL")

est() { cast estimate --rpc-url "$ETH_RPC_URL" --block "$BN" --from "$L1_PROXY" "$1" "$2"; }
AMB_GAS_EST=$(est "$FOREIGN_AMB" "$AMB_DATA")
FX_GAS_EST=$(est "$FX_ROOT" "$FX_DATA")
AMB_ID=$(cast call --rpc-url "$ETH_RPC_URL" --block "$BN" --from "$L1_PROXY" "$FOREIGN_AMB" "$AMB_DATA")

cat <<EOF
Read at Ethereum block $BN ($BH, unix $BT), baseFee $BF wei.

**Gnosis (AMB)** \`$FOREIGN_AMB\` value \`0\` (bridge call gas from the L1 proxy: $AMB_GAS_EST; eth_call message id $AMB_ID):

\`\`\`text
$AMB_DATA
\`\`\`

Inner message delivered by HomeAMB to \`$GNOSIS_PROXY\` (keccak256 $(cast keccak "$AMB_INNER")):

\`\`\`text
$AMB_INNER
\`\`\`

**Polygon (FxPortal)** \`$FX_ROOT\` value \`0\` (bridge call gas from the L1 proxy: $FX_GAS_EST; deadline $FX_DEADLINE = $(date -u -d "@$FX_DEADLINE" +%FT%TZ)):

\`\`\`text
$FX_DATA
\`\`\`

Message delivered by FxChild to \`$POLYGON_PROXY\` (keccak256 $(cast keccak "$FX_MESSAGE")):

\`\`\`text
$FX_MESSAGE
\`\`\`
EOF
