#!/bin/bash

# Function to print usage and exit
print_usage_and_exit() {
    echo "Usage: $0 --network {sepolia,mainnet}"
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
if [ "$NETWORK" != "sepolia" -a "$NETWORK" != "mainnet" ]; then
    echo "Invalid network: $NETWORK"
    print_usage_and_exit
fi


scarb build

declare_class_hash() {
    # Expects an sncast account named after the network.
    sncast --account "$NETWORK" --wait declare --network "$NETWORK" --contract-name "$1"
}

echo "Declaring AirdropClaimCheck"
declare_class_hash AirdropClaimCheck
echo "Declaring Airdrop"
declare_class_hash Airdrop
echo "Declaring Staker"
declare_class_hash governance::staker::Staker
echo "Declaring Governor"
declare_class_hash Governor
