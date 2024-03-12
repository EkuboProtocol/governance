use governance::airdrop::{IAirdropDispatcher};
use governance::governor::{Config as GovernorConfig};
use governance::governor::{IGovernorDispatcher};
use governance::staker::{IStakerDispatcher};
use governance::timelock::{ITimelockDispatcher, TimelockConfig};
use starknet::{ContractAddress};

#[derive(Copy, Drop, Serde)]
pub struct DeploymentParameters {
    pub governor_config: GovernorConfig,
    pub timelock_config: TimelockConfig,
    pub airdrop_root: Option<felt252>,
}

#[derive(Copy, Drop, Serde)]
pub struct DeploymentResult {
    pub staker: IStakerDispatcher,
    pub governor: IGovernorDispatcher,
    pub timelock: ITimelockDispatcher,
    pub airdrop: Option<IAirdropDispatcher>,
}

// This contract makes it easy to deploy a set of governance contracts from a block explorer just by specifying parameters
#[starknet::interface]
pub trait IFactory<TContractState> {
    fn deploy(
        self: @TContractState, token: ContractAddress, params: DeploymentParameters
    ) -> DeploymentResult;
}

#[starknet::contract]
pub mod Factory {
    use core::result::{ResultTrait};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ClassHash, syscalls::{deploy_syscall}, get_caller_address, get_contract_address};
    use super::{
        IFactory, DeploymentParameters, DeploymentResult, ContractAddress, IAirdropDispatcher,
        IGovernorDispatcher, ITimelockDispatcher, IStakerDispatcher
    };

    #[storage]
    struct Storage {
        airdrop_class_hash: ClassHash,
        staker_class_hash: ClassHash,
        governor_class_hash: ClassHash,
        timelock_class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        airdrop_class_hash: ClassHash,
        staker_class_hash: ClassHash,
        governor_class_hash: ClassHash,
        timelock_class_hash: ClassHash
    ) {
        self.airdrop_class_hash.write(airdrop_class_hash);
        self.staker_class_hash.write(staker_class_hash);
        self.governor_class_hash.write(governor_class_hash);
        self.timelock_class_hash.write(timelock_class_hash);
    }

    #[abi(embed_v0)]
    impl FactoryImpl of IFactory<ContractState> {
        fn deploy(
            self: @ContractState, token: ContractAddress, params: DeploymentParameters
        ) -> DeploymentResult {

            let mut staker_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@(token), ref staker_constructor_args);
            let (staker_address, _) = deploy_syscall(
                class_hash: self.staker_class_hash.read(),
                contract_address_salt: 0,
                calldata: staker_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            let mut governor_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@(staker_address, params.governor_config), ref governor_constructor_args);

            let (governor_address, _) = deploy_syscall(
                class_hash: self.governor_class_hash.read(),
                contract_address_salt: 0,
                calldata: governor_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            let airdrop = match params.airdrop_root {
                Option::Some(root) => {
                    let mut airdrop_constructor_args: Array<felt252> = ArrayTrait::new();
                    Serde::serialize(@(token, root), ref airdrop_constructor_args);

                    let (airdrop_address, _) = deploy_syscall(
                        class_hash: self.airdrop_class_hash.read(),
                        contract_address_salt: 0,
                        calldata: airdrop_constructor_args.span(),
                        deploy_from_zero: false,
                    )
                        .unwrap();

                    Option::Some(IAirdropDispatcher { contract_address: airdrop_address })
                },
                Option::None => { Option::None }
            };

            let mut timelock_constructor_args: Array<felt252> = ArrayTrait::new();
            Serde::serialize(
                @(governor_address, params.timelock_config.delay, params.timelock_config.window),
                ref timelock_constructor_args
            );

            let (timelock_address, _) = deploy_syscall(
                class_hash: self.timelock_class_hash.read(),
                contract_address_salt: 0,
                calldata: timelock_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

            DeploymentResult {
                airdrop,
                staker: IStakerDispatcher { contract_address: staker_address },
                governor: IGovernorDispatcher { contract_address: governor_address },
                timelock: ITimelockDispatcher { contract_address: timelock_address }
            }
        }
    }
}
