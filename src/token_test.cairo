use array::{ArrayTrait};
use debug::PrintTrait;
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait, Token};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy(supply: u128) -> ITokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@supply, ref constructor_args);

    let (address, _) = deploy_syscall(
        Token::TEST_CLASS_HASH.try_into().unwrap(), 1, constructor_args.span(), true
    )
        .expect('DEPLOY_FAILED');
    return ITokenDispatcher { contract_address: address };
}


#[test]
#[available_gas(3000000)]
fn test_deploy_constructor() {
    let token = deploy(12345);
    assert(token.balance_of(get_contract_address()) == 12345, 'deployer balance');
    assert(token.balance_of(contract_address_const::<1234512345>()) == 0, 'random balance');
    assert(token.total_supply() == 12345, 'total supply');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_entire_balance() {
    let token = deploy(12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 12345);
    assert(token.balance_of(get_contract_address()) == 0, 'zero after');
    assert(token.balance_of(recipient) == 12345, '12345 after');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_lt_total_balance() {
    let token = deploy(12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 45);
    assert(token.balance_of(get_contract_address()) == 12300, 'remaining');
    assert(token.balance_of(recipient) == 45, '45 transferred');
}
