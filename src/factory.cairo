use starknet::{ContractAddress};

#[derive(Copy, Drop, Serde)]
struct DeploymentParameters {
    benefactor: ContractAddress,
    name: felt252,
    symbol: felt252,
    total_supply: u128,
    airdrop_root: Option<felt252>,
}

#[derive(Copy, Drop, Serde)]
struct DeploymentResult {
    token_address: ContractAddress,
    airdrop_address: Option<ContractAddress>,
}

// This contract makes it easy to deploy a set of governance contracts from a block explorer just by specifying parameters
#[starknet::interface]
trait IFactory<TContractState> {
    fn deploy(self: @TContractState, params: DeploymentParameters) -> DeploymentResult;
}

#[starknet::contract]
mod Factory {
    use core::result::ResultTrait;
    use super::{IFactory, DeploymentParameters, DeploymentResult, ContractAddress};
    use starknet::{ClassHash, deploy_syscall};
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

            IERC20Dispatcher { contract_address: token_address }
                .transfer(params.benefactor, params.total_supply.into());

            let airdrop_address = match params.airdrop_root {
                Option::Some(root) => {
                    let mut airdrop_constructor_args: Array<felt252> = ArrayTrait::new();
                    Serde::serialize(@(token_address, root), ref token_constructor_args);

                    let (airdrop_address, _) = deploy_syscall(
                        class_hash: self.airdrop.read(),
                        contract_address_salt: 0,
                        calldata: airdrop_constructor_args.span(),
                        deploy_from_zero: false,
                    )
                        .unwrap();

                    Option::Some(airdrop_address)
                },
                Option::None => { Option::None }
            };

            DeploymentResult { token_address, airdrop_address, }
        }
    }
}
