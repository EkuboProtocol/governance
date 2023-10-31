use array::{ArrayTrait};
use debug::PrintTrait;
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, Factory, DeploymentParameters
};
use governance::governance_token::{GovernanceToken};
use governance::governor::{Governor};
use governance::timelock::{Timelock};
use governance::airdrop::{Airdrop};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
};
use starknet::class_hash::{Felt252TryIntoClassHash};
use starknet::testing::{set_contract_address, set_block_timestamp, pop_log};
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy() -> IFactoryDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(
        @(
            GovernanceToken::TEST_CLASS_HASH,
            Airdrop::TEST_CLASS_HASH,
            Governor::TEST_CLASS_HASH,
            Timelock::TEST_CLASS_HASH
        ),
        ref constructor_args
    );

    let (address, _) = deploy_syscall(
        class_hash: Factory::TEST_CLASS_HASH.try_into().unwrap(),
        contract_address_salt: 0,
        calldata: constructor_args.span(),
        deploy_from_zero: true
    )
        .expect('DEPLOY_FAILED');
    return IFactoryDispatcher { contract_address: address };
}


#[test]
#[available_gas(3000000)]
fn test_deploy() {
    let factory = deploy();

    factory
        .deploy(
            DeploymentParameters {
                benefactor: contract_address_const::<12345>(),
                name: 'token',
                symbol: 'tk',
                total_supply: 5678,
            }
        );
}
