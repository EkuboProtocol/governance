#!/usr/bin/env bash

set -euo pipefail

print_usage() {
    echo "Usage: $0 --network {sepolia,mainnet} [--url RPC_URL] [--dry-run]"
    echo "RPC_URL may also be provided through STARKNET_RPC_URL."
}

NETWORK=""
RPC_URL="${STARKNET_RPC_URL:-}"
DRY_RUN=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --network)
            [[ "$#" -ge 2 ]] || {
                print_usage
                exit 1
            }
            NETWORK="$2"
            shift 2
            ;;
        --url)
            [[ "$#" -ge 2 ]] || {
                print_usage
                exit 1
            }
            RPC_URL="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown parameter: $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

if [[ "$NETWORK" != "sepolia" && "$NETWORK" != "mainnet" ]]; then
    echo "Invalid network: ${NETWORK:-<unset>}" >&2
    print_usage
    exit 1
fi

NETWORK_ARGS=(--network "$NETWORK")
if [[ -n "$RPC_URL" ]]; then
    NETWORK_ARGS=(--url "$RPC_URL")
fi

scarb --release build

declare_class_hash() {
    local contract_name="$1"
    echo "Declaring $contract_name"
    # Expects an sncast account named after the network.
    if [[ "$DRY_RUN" == true ]]; then
        sncast \
            --account "$NETWORK" \
            --scarb-profile release \
            --wait \
            declare \
            "${NETWORK_ARGS[@]}" \
            --contract-name "$contract_name" \
            --dry-run
    else
        sncast \
            --account "$NETWORK" \
            --scarb-profile release \
            --wait \
            declare \
            "${NETWORK_ARGS[@]}" \
            --contract-name "$contract_name"
    fi
}

CONTRACTS=(
    AirdropClaimCheck
    Airdrop
    governance::staker::Staker
    governance::staker_v2::Staker
    Governor
)

for contract_name in "${CONTRACTS[@]}"; do
    declare_class_hash "$contract_name"
done
