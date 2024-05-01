#!/bin/bash

# Function to print usage and exit
print_usage_and_exit() {
    echo "Usage: $0 --network {sepolia,goerli-1,mainnet}"
    exit 1
}

# Ensure there are exactly two arguments
if [ "$#" -ne 2 ]; then
    print_usage_and_exit
fi

# Parse the arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --network)
            NETWORK="$2"
            shift
            ;;
        *)
            echo "Unknown parameter passed: $1"
            print_usage_and_exit
            ;;
    esac
    shift
done

# Ensure network is valid
if [ "$NETWORK" != "sepolia" -a "$NETWORK" != "mainnet" -a "$NETWORK" != "goerli-1" ]; then
    echo "Invalid network: $NETWORK"
    print_usage_and_exit
fi


scarb build

declare_class_hash() {
    local class_name=$1
    starkli declare --watch --network "$NETWORK" --keystore-password "$STARKNET_KEYSTORE_PASSWORD" --casm-file  "target/dev/governance_${class_name}.compiled_contract_class.json" "target/dev/governance_${class_name}.contract_class.json"
}

echo "Declaring AirdropClaimCheck"
AIRDROP_CLAIM_CHECK_CLASS_HASH=$(declare_class_hash AirdropClaimCheck)
echo "Declaring Airdrop"
AIRDROP_CLASS_HASH=$(declare_class_hash Airdrop)
echo "Declaring Staker"
STAKER_CLASS_HASH=$(declare_class_hash Staker)
echo "Declaring Governor"
GOVERNOR_CLASS_HASH=$(declare_class_hash Governor)
echo "Declaring Timelock"
TIMELOCK_CLASS_HASH=$(declare_class_hash Timelock)
echo "Declaring Factory"
FACTORY_CLASS_HASH=$(declare_class_hash Factory)

echo "AirdropClaimCheck @ $AIRDROP_CLAIM_CHECK_CLASS_HASH"
echo "Airdrop @ $AIRDROP_CLASS_HASH"
echo "Staker @ $STAKER_CLASS_HASH"
echo "Governor @ $GOVERNOR_CLASS_HASH"
echo "Timelock @ $TIMELOCK_CLASS_HASH"
echo "Factory @ $FACTORY_CLASS_HASH"

# starkli deploy --max-fee 0.001 --watch --network "$NETWORK" --keystore-password "$STARKNET_KEYSTORE_PASSWORD" "$AIRDROP_CLAIM_CHECK_CLASS_HASH"
# starkli deploy --max-fee 0.001 --watch --network "$NETWORK" --keystore-password "$STARKNET_KEYSTORE_PASSWORD" "$FACTORY_CLASS_HASH" "$STAKER_CLASS_HASH" "$GOVERNOR_CLASS_HASH" "$TIMELOCK_CLASS_HASH"