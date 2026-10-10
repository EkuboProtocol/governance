#!/usr/bin/env bash
# Read-only CCIP lane snapshot for T2 (EKU-1232). Public RPC reads only; pins every read to one block per chain.
set -euo pipefail
SEP=${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
BNBT=${BNB_TESTNET_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}
MONT=${MONAD_TESTNET_RPC_URL:-https://testnet-rpc.monad.xyz}
SEPSEL=16015286601757825753; BNBSEL=13264668187771770619; MONSEL=2183018362218727504
R_SEP=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; R_BNB=0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f; R_MON=0x5aD0A67f4Da0E8665a3fbf15E4215A780407Cf33
pin() { cast block "${2:-finalized}" -r "$1" -f number; }
B_SEP=${B_SEP:-$(pin $SEP)}; B_BNB=${B_BNB:-$(pin $BNBT)}; B_MON=${B_MON:-$(pin $MONT)}
hdr() { echo "## $1 chainId=$(cast chain-id -r $2) block=$3 hash=$(cast block $3 -r $2 -f hash) timestamp=$(cast block $3 -r $2 -f timestamp) ($(date -u -d @$(cast block $3 -r $2 -f timestamp) +%FT%TZ))"; }
ch() { local c; c=$(cast code "$1" -r "$2" -B "$3"); echo "codehash=$(cast keccak $c) codesize=$(( (${#c}-2)/2 ))"; }
tv() { cast call "$1" 'typeAndVersion()(string)' -r "$2" --block "$3"; }
echo "# CCIP T2 lane snapshot generated $(date -u +%FT%TZ) cast $(cast --version | head -1)"
hdr "Ethereum Sepolia" $SEP $B_SEP
echo "Router $R_SEP $(tv $R_SEP $SEP $B_SEP) $(ch $R_SEP $SEP $B_SEP) owner=$(cast call $R_SEP 'owner()(address)' -r $SEP --block $B_SEP)"
echo "Router.getWrappedNative=$(cast call $R_SEP 'getWrappedNative()(address)' -r $SEP --block $B_SEP) getArmProxy=$(cast call $R_SEP 'getArmProxy()(address)' -r $SEP --block $B_SEP)"
for d in "BNB97:$BNBSEL" "MON10143:$MONSEL"; do n=${d%%:*}; s=${d##*:}
  on=$(cast call $R_SEP 'getOnRamp(uint64)(address)' $s -r $SEP --block $B_SEP)
  echo "Router.getOnRamp($n sel $s)=$on isChainSupported=$(cast call $R_SEP 'isChainSupported(uint64)(bool)' $s -r $SEP --block $B_SEP) | $(tv $on $SEP $B_SEP) $(ch $on $SEP $B_SEP)"
  echo "  OnRamp.getDestChainConfig($n)=$(cast call $on 'getDestChainConfig(uint64)((address,uint64,uint8,bool,uint16,uint16,uint32,address,address[],address[],bytes))' $s -r $SEP --block $B_SEP)"
  fq=$(cast call $on 'getDynamicConfig()((address,bool,address))' -r $SEP --block $B_SEP | sed 's/[(),]/ /g' | awk '{print $1}')
  echo "  OnRamp.getDynamicConfig.feeQuoter=$fq $(tv $fq $SEP $B_SEP)"
  echo "  FeeQuoter.getDestChainConfig($n)=$(cast call $fq 'getDestChainConfig(uint64)((bool,uint32,uint32,uint32,uint8,bytes4,uint16,uint32,uint32,uint16,uint8))' $s -r $SEP --block $B_SEP)"
done
echo "OnRamp.getStaticConfig=$(cast call $on 'getStaticConfig()((uint64,address,uint32,address))' -r $SEP --block $B_SEP)"
for n in BNB97 MON10143; do if [ $n = BNB97 ]; then u=$BNBT; r=$R_BNB; b=$B_BNB; else u=$MONT; r=$R_MON; b=$B_MON; fi
  hdr "$n" $u $b
  echo "Router $r $(tv $r $u $b) $(ch $r $u $b) owner=$(cast call $r 'owner()(address)' -r $u --block $b)"
  echo "Router.getOnRamp(Sepolia)=$(cast call $r 'getOnRamp(uint64)(address)' $SEPSEL -r $u --block $b)"
  for off in $(cast call $r 'getOffRamps()((uint64,address)[])' -r $u --block $b | tr ')' '\n' | grep "$SEPSEL" | grep -o '0x[0-9a-fA-F]\{40\}'); do
    echo "Router.getOffRamps[Sepolia] $off isOffRamp=$(cast call $r 'isOffRamp(uint64,address)(bool)' $SEPSEL $off -r $u --block $b) $(tv $off $u $b) $(ch $off $u $b)"
    if [[ "$(tv $off $u $b)" == *"OffRamp 2.0.0"* ]]; then
      echo "  OffRamp.getStaticConfig=$(cast call $off 'getStaticConfig()((uint64,uint16,address,address,uint32))' -r $u --block $b)"
      echo "  OffRamp.getSourceChainConfig(Sepolia)=$(cast call $off 'getSourceChainConfig(uint64)((address,bool,bytes[],address[],address[]))' $SEPSEL -r $u --block $b)"
    fi
  done
done
