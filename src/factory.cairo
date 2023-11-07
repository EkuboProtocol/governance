use starknet::{ContractAddress};
use governance::governor::{Config as GovernorConfig};
use governance::governor::{IGovernorDispatcher};
use governance::governance_token::{IGovernanceTokenDispatcher};
use governance::airdrop::{IAirdropDispatcher};
use governance::timelock::{ITimelockDispatcher};

#[derive(Copy, Drop, Serde)]
struct AirdropConfig {
    root: felt252,
    total: u128,
}

#[derive(Copy, Drop, Serde)]
struct TimelockConfig {
    delay: u64,
    window: u64,
}

#[derive(Copy, Drop, Serde)]
struct DeploymentParameters {
    name: felt252,
    symbol: felt252,
    total_supply: u128,
    governor_config: GovernorConfig,
    timelock_config: TimelockConfig,
    airdrop_config: Option<AirdropConfig>,
}

#[derive(Copy, Drop, Serde)]
struct DeploymentResult {
    token: IGovernanceTokenDispatcher,
    governor: IGovernorDispatcher,
    timelock: ITimelockDispatcher,
    airdrop: Option<IAirdropDispatcher>,
}

// This contract makes it easy to deploy a set of governance contracts from a block explorer just by specifying parameters
#[starknet::interface]
trait IFactory<TContractState> {
    fn deploy(self: @TContractState, params: DeploymentParameters) -> DeploymentResult;
}

#[starknet::contract]
mod Factory {
    use super::{
        IFactory, DeploymentParameters, DeploymentResult, ContractAddress,
        IGovernanceTokenDispatcher, IAirdropDispatcher, IGovernorDispatcher, ITimelockDispatcher
    };
    use core::result::{ResultTrait};
    use starknet::{ClassHash, deploy_syscall, get_caller_address};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

    #[storage]
    struct Storage {
        governance_token: ClassHash,
        airdrop: ClassHash,
        governor: ClassHash,
        timelock: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        governance_token: ClassHash,
        airdrop: ClassHash,
        governor: ClassHash,
        timelock: ClassHash
    ) {
        self.governance_token.write(governance_token);
        self.airdrop.write(airdrop);
        self.governor.write(governor);
        self.timelock.write(timelock);
    }

    #[external(v0)]
    impl FactoryImpl of IFactory<ContractState> {
        fn deploy(self: @ContractState, params: DeploymentParameters) -> DeploymentResult {
            let mut token_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(
                @(params.name, params.symbol, params.total_supply), ref token_constructor_args
            );

            let (token_address, _) = deploy_syscall(
                class_hash: self.governance_token.read(),
                contract_address_salt: 0,
                calldata: token_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            let erc20 = IERC20Dispatcher { contract_address: token_address };

            let mut governor_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(
                @(token_address, params.governor_config), ref governor_constructor_args
            );

            let (governor_address, _) = deploy_syscall(
                class_hash: self.governor.read(),
                contract_address_salt: 0,
                calldata: governor_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            let (airdrop, remaining_amount) = match params.airdrop_config {
                Option::Some(config) => {
                    let mut airdrop_constructor_args: Array<felt252> = ArrayTrait::new();
                    Serde::serialize(@(token_address, config.root), ref airdrop_constructor_args);

                    let (airdrop_address, _) = deploy_syscall(
                        class_hash: self.airdrop.read(),
                        contract_address_salt: 0,
                        calldata: airdrop_constructor_args.span(),
                        deploy_from_zero: false,
                    )
                        .unwrap();

                    assert(config.total <= params.total_supply, 'AIRDROP_GT_SUPPLY');

                    (
                        Option::Some(IAirdropDispatcher { contract_address: airdrop_address }),
                        params.total_supply - config.total
                    )
                },
                Option::None => { (Option::None, params.total_supply) }
            };

            erc20.transfer(get_caller_address(), remaining_amount.into());

            let mut timelock_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(
                @(governor_address, params.timelock_config.delay, params.timelock_config.window),
                ref timelock_constructor_args
            );

            let (timelock_address, _) = deploy_syscall(
                class_hash: self.timelock.read(),
                contract_address_salt: 0,
                calldata: timelock_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            DeploymentResult {
                token: IGovernanceTokenDispatcher { contract_address: token_address },
                airdrop,
                governor: IGovernorDispatcher { contract_address: governor_address },
                timelock: ITimelockDispatcher { contract_address: timelock_address }
            }
        }
    }
}
