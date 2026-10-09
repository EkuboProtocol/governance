#!/usr/bin/env bash
# Builds the Ethereum-side call for one Governor message per chain (Gnosis AMB, Polygon FxPortal) and checks it
# against live Ethereum state. Prints, per message, the L1 target, value, nonce and data that
# StarknetOwnerProxy.execute must be called with, the StarknetOwnerProxy payload and L2->L1 message hash, the
# inner message delivered on the destination chain with its keccak256, the decoded Call[] and a gas estimate from
# the L1 proxy.
#
# Usage:
#   GNOSIS_PROXY=0x... POLYGON_PROXY=0x... PROPOSAL_CREATED=<unix seconds> FX_DEADLINE=<unix seconds> \
#     ETH_RPC_URL=... [GNOSIS_RPC_URL=... POLYGON_RPC_URL=...] [EXPECT_NONCE=<n>] ./script/wave4-l1-calldata.sh
#
# PROPOSAL_CREATED is the Starknet timestamp at which the proposal is (or will be) created. The Governor lets the
# L1 message be relayed no earlier than PROPOSAL_CREATED + 352800, so the script fails unless
#   PROPOSAL_CREATED + 352800 < FX_DEADLINE <= PROPOSAL_CREATED + 352800 + 14 days   (CSO EKU-1064 D4a).
# DEADLINE_CHECK_ONLY=1 stops after that check (no RPC needed).
#
# Nonces are read live from StarknetOwnerProxy.currentNonce(): Gnosis gets currentNonce, Polygon currentNonce + 1.
# With EXPECT_NONCE set the script fails if currentNonce differs. With GNOSIS_RPC_URL / POLYGON_RPC_URL set it also
# checks on each chain that Positions and Orders v3.2 are owned by the company key and, if the proxy is deployed,
# that its runtime code hash equals the reference build.
#
# ACTION=handover (the only action) builds [Positions.requestOwnershipHandover(), Orders.requestOwnershipHandover()].
set -euo pipefail

ACTION="${ACTION:-handover}"
if [[ "$ACTION" != handover ]]; then
  echo "only ACTION=handover is implemented" >&2
  exit 1
fi

# ---- D4a: deadline cap (runs before any RPC call) ----
GOVERNOR_EXEC_DELAY=352800
FX_DEADLINE_WINDOW=$((14 * 86400))
: "${PROPOSAL_CREATED:?PROPOSAL_CREATED (unix seconds of proposal creation) is required}"
: "${FX_DEADLINE:?FX_DEADLINE (unix seconds) is required}"
for v in PROPOSAL_CREATED FX_DEADLINE; do
  if ! [[ "${!v}" =~ ^[0-9]{1,12}$ ]]; then
    echo "$v must be a decimal unix timestamp, got '${!v}'" >&2
    exit 1
  fi
done
EARLIEST_RELAY=$((10#$PROPOSAL_CREATED + GOVERNOR_EXEC_DELAY))
DEADLINE_MAX=$((EARLIEST_RELAY + FX_DEADLINE_WINDOW))
FX_DEADLINE=$((10#$FX_DEADLINE))
if ((FX_DEADLINE <= EARLIEST_RELAY)); then
  echo "FX_DEADLINE $FX_DEADLINE must be after PROPOSAL_CREATED + $GOVERNOR_EXEC_DELAY = $EARLIEST_RELAY" >&2
  exit 1
fi
if ((FX_DEADLINE > DEADLINE_MAX)); then
  echo "FX_DEADLINE $FX_DEADLINE must be at most PROPOSAL_CREATED + $GOVERNOR_EXEC_DELAY + 14 days = $DEADLINE_MAX" >&2
  exit 1
fi
if [[ "${DEADLINE_CHECK_ONLY:-}" == 1 ]]; then
  echo "deadline ok: $EARLIEST_RELAY < $FX_DEADLINE <= $DEADLINE_MAX"
  exit 0
fi

: "${GNOSIS_PROXY:?}" "${POLYGON_PROXY:?}" "${ETH_RPC_URL:?}"

GOVERNOR=0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd
L1_PROXY=0x1e0ef4162e42c9bf820c307218c4e41ccca6e9cc
FOREIGN_AMB=0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e
FX_ROOT=0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2
AMB_GAS=500000
POSITIONS=0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326
ORDERS=0x9bB520B6192F71ec3D015C8a74F914f9c94bF794
COMPANY_KEY=0x00000c771f6176268d5a9846e0956c3ef58597a1
AMB_CODEHASH=0x15bac46554937c2ba14f2252d72c37ce03a46ce19b236f5b100728f73da951c9
FX_CODEHASH=0xfd5a27dda70171125e9b039861893cfd417b6ae8ec6ac9c3ce13550cae492246
CALL_T='(address,uint256,bytes)[]'

lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
fail() { echo "$*" >&2; exit 1; }

REQ=$(cast calldata 'requestOwnershipHandover()')
CALLS="[($POSITIONS,0,$REQ),($ORDERS,0,$REQ)]"
EXPECTED_DECODED=$(lc "[($POSITIONS, 0, $REQ), ($ORDERS, 0, $REQ)]")

AMB_INNER=$(cast calldata "executeBatch($CALL_T)" "$CALLS")
AMB_DATA=$(cast calldata 'requireToPassMessage(address,bytes,uint256)' "$GNOSIS_PROXY" "$AMB_INNER" "$AMB_GAS")

FX_MESSAGE=$(cast abi-encode "f($CALL_T,uint64)" "$CALLS" "$FX_DEADLINE")
FX_DATA=$(cast calldata 'sendMessageToChild(address,bytes)' "$POLYGON_PROXY" "$FX_MESSAGE")

# Decode what is actually delivered and require exactly the two handover requests.
AMB_DECODED=$(lc "$(cast decode-calldata "executeBatch($CALL_T)" "$AMB_INNER")")
[[ "$AMB_DECODED" == "$EXPECTED_DECODED" ]] || fail "AMB Call[] decodes to $AMB_DECODED, expected $EXPECTED_DECODED"
mapfile -t FX_DECODED < <(cast decode-abi -i "f($CALL_T,uint64)" "$FX_MESSAGE")
[[ "$(lc "${FX_DECODED[0]}")" == "$EXPECTED_DECODED" ]] || fail "Fx Call[] decodes to ${FX_DECODED[0]}"
[[ "${FX_DECODED[1]%% *}" == "$FX_DEADLINE" ]] || fail "Fx deadline decodes to ${FX_DECODED[1]}"

BN=$(cast block-number --rpc-url "$ETH_RPC_URL")
BH=$(cast block "$BN" -f hash --rpc-url "$ETH_RPC_URL")
BT=$(cast block "$BN" -f timestamp --rpc-url "$ETH_RPC_URL")
BF=$(cast block "$BN" -f baseFeePerGas --rpc-url "$ETH_RPC_URL")
ecall() { cast call --rpc-url "$ETH_RPC_URL" --block "$BN" "$@"; }

L2_OWNER=$(ecall "$L1_PROXY" 'l2Owner()(uint256)')
[[ "${L2_OWNER%% *}" == "$(cast to-dec "$GOVERNOR")" ]] || fail "L1 proxy l2Owner is $L2_OWNER, not the Governor"
NONCE=$(ecall "$L1_PROXY" 'currentNonce()(uint64)')
NONCE=${NONCE%% *}
if [[ -n "${EXPECT_NONCE:-}" && "$NONCE" != "$EXPECT_NONCE" ]]; then
  fail "StarknetOwnerProxy.currentNonce() is $NONCE at block $BN, expected $EXPECT_NONCE"
fi
NONCE_AMB=$NONCE
NONCE_FX=$((NONCE + 1))

# Payload as decimal words, one per line.
payload() { ecall "$L1_PROXY" 'getPayload(address,uint256,uint64,bytes)(uint256[])' "$1" 0 "$2" "$3" --json | jq -r '.[0][]'; }
msg_hash() {
  # keccak256(abi.encodePacked(uint256 Governor, uint256 L1 proxy, uint256 payload.length, uint256[] payload))
  local words len packed w
  mapfile -t words <<<"$1"
  len=${#words[@]}
  packed="0x$(cast to-uint256 "$GOVERNOR" | cut -c3-)$(cast to-uint256 "$L1_PROXY" | cut -c3-)$(cast to-uint256 "$len" | cut -c3-)"
  for w in "${words[@]}"; do packed+=$(cast to-uint256 "$w" | cut -c3-); done
  ((${#packed} == 2 + 64 * (3 + len))) || fail "bad payload packing"
  cast keccak "$packed"
}
payload_json() { jq -R . <<<"$1" | jq -sc .; }
AMB_PAYLOAD=$(payload "$FOREIGN_AMB" "$NONCE_AMB" "$AMB_DATA")
FX_PAYLOAD=$(payload "$FX_ROOT" "$NONCE_FX" "$FX_DATA")
AMB_MSG_HASH=$(msg_hash "$AMB_PAYLOAD")
FX_MSG_HASH=$(msg_hash "$FX_PAYLOAD")

est() { cast estimate --rpc-url "$ETH_RPC_URL" --block "$BN" --from "$L1_PROXY" "$1" "$2"; }
AMB_GAS_EST=$(est "$FOREIGN_AMB" "$AMB_DATA")
FX_GAS_EST=$(est "$FX_ROOT" "$FX_DATA")
AMB_ID=$(ecall --from "$L1_PROXY" "$FOREIGN_AMB" "$AMB_DATA")

# Destination-chain checks (optional): company key still owns exactly these surfaces, proxy code matches reference.
dest_check() {
  local name=$1 rpc=$2 proxy=$3 ref=$4 o code
  for c in "$POSITIONS" "$ORDERS"; do
    o=$(cast call --rpc-url "$rpc" "$c" 'owner()(address)')
    [[ "$(lc "$o")" == "$(lc "$COMPANY_KEY")" ]] || fail "$name: owner() of $c is $o, not the company key"
  done
  code=$(cast code --rpc-url "$rpc" "$proxy")
  if [[ "$code" == 0x ]]; then
    echo "$name: Positions/Orders owned by company key; proxy $proxy NOT deployed yet"
  else
    [[ "$(cast keccak "$code")" == "$ref" ]] || fail "$name: proxy $proxy code hash $(cast keccak "$code") != reference $ref"
    echo "$name: Positions/Orders owned by company key; proxy $proxy code hash = reference $ref"
  fi
}
DEST=""
[[ -n "${GNOSIS_RPC_URL:-}" ]] && DEST+="$(dest_check Gnosis "$GNOSIS_RPC_URL" "$GNOSIS_PROXY" "$AMB_CODEHASH")"$'\n'
[[ -n "${POLYGON_RPC_URL:-}" ]] && DEST+="$(dest_check Polygon "$POLYGON_RPC_URL" "$POLYGON_PROXY" "$FX_CODEHASH")"$'\n'
[[ -n "$DEST" ]] || DEST="(destination checks skipped: GNOSIS_RPC_URL / POLYGON_RPC_URL not set)"$'\n'

DECODED_TABLE="| # | target | value | data |
|---|---|---|---|
| 0 | \`$POSITIONS\` (Positions 192-bit v3.2.0) | 0 | \`$REQ\` \`requestOwnershipHandover()\` |
| 1 | \`$ORDERS\` (Orders 192-bit v3.2.0) | 0 | \`$REQ\` \`requestOwnershipHandover()\` |"

cat <<EOF
Read at Ethereum block $BN ($BH, unix $BT), baseFee $BF wei. StarknetOwnerProxy \`$L1_PROXY\` currentNonce $NONCE, l2Owner = Governor \`$GOVERNOR\`.

Fx deadline check (CSO EKU-1064 D4a): proposal created $PROPOSAL_CREATED ($(date -u -d "@$PROPOSAL_CREATED" +%FT%TZ)); earliest relay $EARLIEST_RELAY ($(date -u -d "@$EARLIEST_RELAY" +%FT%TZ)) < deadline $FX_DEADLINE ($(date -u -d "@$FX_DEADLINE" +%FT%TZ)) <= $DEADLINE_MAX ($(date -u -d "@$DEADLINE_MAX" +%FT%TZ)): OK

Destination checks:
$DEST
| Message | Nonce | L1 target | L1 value | L1 call | Destination | Inner message keccak256 | L2→L1 message hash |
|---|---|---|---|---|---|---|---|
| Gnosis | $NONCE_AMB | \`$FOREIGN_AMB\` (ForeignAMB) | 0 | \`requireToPassMessage($GNOSIS_PROXY, executeBatch(calls), $AMB_GAS)\` | Gnosis 100, \`AMBOwnerProxy\` \`$GNOSIS_PROXY\` | \`$(cast keccak "$AMB_INNER")\` | \`$AMB_MSG_HASH\` |
| Polygon | $NONCE_FX | \`$FX_ROOT\` (FxRoot) | 0 | \`sendMessageToChild($POLYGON_PROXY, abi.encode(calls, $FX_DEADLINE))\` | Polygon 137, \`FxPortalOwnerProxy\` \`$POLYGON_PROXY\` | \`$(cast keccak "$FX_MESSAGE")\` | \`$FX_MSG_HASH\` |

Decoded \`Call[]\` (identical in both messages, checked by decoding the delivered bytes):

$DECODED_TABLE

### Exact L1 calldata per message

**Gnosis (AMB)** nonce $NONCE_AMB \`$FOREIGN_AMB\` value \`0\` (bridge call gas from the L1 proxy: $AMB_GAS_EST; eth_call message id $AMB_ID):

\`\`\`text
$AMB_DATA
\`\`\`

StarknetOwnerProxy payload, decimal felts (\`getPayload($FOREIGN_AMB, 0, $NONCE_AMB, data)\`):

\`\`\`text
$(payload_json "$AMB_PAYLOAD")
\`\`\`

Inner message delivered by HomeAMB to \`$GNOSIS_PROXY\` (keccak256 $(cast keccak "$AMB_INNER")):

\`\`\`text
$AMB_INNER
\`\`\`

**Polygon (FxPortal)** nonce $NONCE_FX \`$FX_ROOT\` value \`0\` (bridge call gas from the L1 proxy: $FX_GAS_EST; deadline $FX_DEADLINE = $(date -u -d "@$FX_DEADLINE" +%FT%TZ)):

\`\`\`text
$FX_DATA
\`\`\`

StarknetOwnerProxy payload, decimal felts (\`getPayload($FX_ROOT, 0, $NONCE_FX, data)\`):

\`\`\`text
$(payload_json "$FX_PAYLOAD")
\`\`\`

Message delivered by FxChild to \`$POLYGON_PROXY\` (keccak256 $(cast keccak "$FX_MESSAGE")):

\`\`\`text
$FX_MESSAGE
\`\`\`
EOF
