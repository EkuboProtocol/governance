use array::{ArrayTrait};
use debug::PrintTrait;
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait, Token};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
};
use starknet::class_hash::Felt252TryIntoClassHash;
use starknet::testing::{set_contract_address};
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy(name: felt252, symbol: felt252, supply: u128) -> ITokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@name, ref constructor_args);
    Serde::serialize(@symbol, ref constructor_args);
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
    let token = deploy('Governance Token', 'GT', 12345);
    assert(token.name() == 'Governance Token', 'name');
    assert(token.symbol() == 'GT', 'symbol');
    assert(token.balance_of(get_contract_address()) == 12345, 'deployer balance');
    assert(token.balance_of(contract_address_const::<1234512345>()) == 0, 'random balance');
    assert(token.total_supply() == 12345, 'total supply');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_entire_balance() {
    let token = deploy('Governance Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 12345);
    assert(token.balance_of(get_contract_address()) == 0, 'zero after');
    assert(token.balance_of(recipient) == 12345, '12345 after');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_lt_total_balance() {
    let token = deploy('Governance Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 45);
    assert(token.balance_of(get_contract_address()) == 12300, 'remaining');
    assert(token.balance_of(recipient) == 45, '45 transferred');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_INSUFFICIENT_BALANCE', 'ENTRYPOINT_FAILED'))]
fn test_transfer_gt_total_balance() {
    let token = deploy('Governance Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 12346);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_AMOUNT_OVERFLOW', 'ENTRYPOINT_FAILED'))]
fn test_transfer_overflow() {
    let token = deploy('Governance Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, u256 { high: 1, low: 0 });
}

#[test]
#[available_gas(3000000)]
fn test_approve_sets_allowance() {
    let token = deploy('Governance Token', 'GT', 12345);

    let spender = contract_address_const::<12345>();
    token.approve(spender, 5151);
    assert(token.allowance(get_contract_address(), spender) == 5151, 'allowance');
}

#[test]
#[available_gas(3000000)]
fn test_approve_allows_transfer_from() {
    let token = deploy('Governance Token', 'GT', 12345);

    let owner = get_contract_address();
    let spender = contract_address_const::<12345>();
    let recipient = contract_address_const::<12346>();
    token.approve(spender, 12345);
    set_contract_address(spender);

    assert(token.transfer_from(owner, recipient, 12345), 'transfer_from');
    assert(token.balance_of(owner) == 0, 'balance_of(from)');
    assert(token.balance_of(recipient) == 12345, 'balance_of(to)');
    assert(token.balance_of(spender) == 0, 'balance_of(spender)');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_FROM_ALLOWANCE', 'ENTRYPOINT_FAILED'))]
fn test_transfer_from_insufficient_allowance() {
    let token = deploy('Governance Token', 'GT', 12345);

    let owner = get_contract_address();
    let spender = contract_address_const::<12345>();
    let recipient = contract_address_const::<12346>();
    token.approve(spender, 12345);
    set_contract_address(spender);
    token.transfer_from(owner, recipient, 12346);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('APPROVE_AMOUNT_OVERFLOW', 'ENTRYPOINT_FAILED'))]
fn test_approve_overflow() {
    let token = deploy('Governance Token', 'GT', 12345);

    let spender = contract_address_const::<12345>();
    let recipient = contract_address_const::<12346>();
    token.approve(spender, u256 { high: 1, low: 0 });
}
