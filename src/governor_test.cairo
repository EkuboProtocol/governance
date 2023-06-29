use array::{ArrayTrait};
use debug::PrintTrait;
use governance::governor::{IGovernorDispatcher, IGovernorDispatcherTrait, Governor};
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};
use governance::token_test::{deploy as deploy_token};
use serde::Serde;

fn deploy(token: ITokenDispatcher) -> IGovernorDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@token, ref constructor_args);

    let (address, _) = deploy_syscall(
        Governor::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IGovernorDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_governance_deploy() {
    let token = deploy_token('Governor', 'GT', 1000);
    let governance = deploy(token);
}
