use array::{ArrayTrait};
use debug::PrintTrait;
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait, Token};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy() -> ITokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();

    let (address, _) = deploy_syscall(
        Token::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_FAILED');
    return ITokenDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_total_supply() {
    let token = deploy();
}
