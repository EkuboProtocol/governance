use governance::governor::{Config as GovernorConfig};
use governance::governor::{IGovernorDispatcher};
use governance::staker::{IStakerDispatcher};
use governance::timelock::{ITimelockDispatcher, Config as TimelockConfig};
use starknet::{ClassHash, ContractAddress};

#[derive(Copy, Drop, Serde)]
pub struct DeploymentParameters {
    pub governor_config: GovernorConfig,
    pub timelock_config: TimelockConfig,
}

#[derive(Copy, Drop, Serde)]
pub struct DeploymentResult {
    pub staker: IStakerDispatcher,
    pub governor: IGovernorDispatcher,
    pub timelock: ITimelockDispatcher,
}

// This contract makes it easy to deploy a set of governance contracts from a block explorer just by specifying parameters
#[starknet::interface]
pub trait IFactory<TContractState> {
    fn get_staker_class_hash(self: @TContractState) -> ClassHash;
    fn get_governor_class_hash(self: @TContractState) -> ClassHash;
    fn get_timelock_class_hash(self: @TContractState) -> ClassHash;

    fn deploy(
        ref self: TContractState, token: ContractAddress, params: DeploymentParameters
    ) -> DeploymentResult;
}

#[starknet::contract]
pub mod Factory {
    use core::result::{ResultTrait};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{syscalls::{deploy_syscall}, get_caller_address, get_contract_address};
    use super::{
        ClassHash, IFactory, DeploymentParameters, DeploymentResult, ContractAddress,
        IGovernorDispatcher, ITimelockDispatcher, IStakerDispatcher
    };

    #[storage]
    struct Storage {
        staker_class_hash: ClassHash,
        governor_class_hash: ClassHash,
        timelock_class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        staker_class_hash: ClassHash,
        governor_class_hash: ClassHash,
        timelock_class_hash: ClassHash
    ) {
        self.staker_class_hash.write(staker_class_hash);
        self.governor_class_hash.write(governor_class_hash);
        self.timelock_class_hash.write(timelock_class_hash);
    }

    #[abi(embed_v0)]
    impl FactoryImpl of IFactory<ContractState> {
        fn get_staker_class_hash(self: @ContractState) -> ClassHash {
            self.staker_class_hash.read()
        }
        fn get_governor_class_hash(self: @ContractState) -> ClassHash {
            self.governor_class_hash.read()
        }
        fn get_timelock_class_hash(self: @ContractState) -> ClassHash {
            self.timelock_class_hash.read()
        }

        fn deploy(
            ref self: ContractState, token: ContractAddress, params: DeploymentParameters
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
            Serde::serialize(
                @(staker_address, params.governor_config), ref governor_constructor_args
            );

            let (governor_address, _) = deploy_syscall(
                class_hash: self.governor_class_hash.read(),
                contract_address_salt: 0,
                calldata: governor_constructor_args.span(),
                deploy_from_zero: false,
            )
                .unwrap();

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
                staker: IStakerDispatcher { contract_address: staker_address },
                governor: IGovernorDispatcher { contract_address: governor_address },
                timelock: ITimelockDispatcher { contract_address: timelock_address }
            }
        }
    }
}
