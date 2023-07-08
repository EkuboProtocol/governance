use array::{ArrayTrait};
use debug::PrintTrait;
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait, Token};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
};
use starknet::class_hash::Felt252TryIntoClassHash;
use starknet::testing::{set_contract_address, set_block_timestamp};
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy(name: felt252, symbol: felt252, supply: u128) -> ITokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@name, ref constructor_args);
    Serde::serialize(@symbol, ref constructor_args);
    Serde::serialize(@supply, ref constructor_args);

    let (address, _) = deploy_syscall(
        Token::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_TK_FAILED');
    return ITokenDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_deploy_constructor() {
    let token = deploy('Governor Token', 'GT', 12345);
    assert(token.name() == 'Governor Token', 'name');
    assert(token.symbol() == 'GT', 'symbol');
    assert(token.balanceOf(get_contract_address()) == 12345, 'deployer balance');
    assert(token.balanceOf(contract_address_const::<1234512345>()) == 0, 'random balance');
    assert(token.total_supply() == 12345, 'total supply');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_entire_balance() {
    let token = deploy('Governor Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 12345);
    assert(token.balanceOf(get_contract_address()) == 0, 'zero after');
    assert(token.balanceOf(recipient) == 12345, '12345 after');
}

#[test]
#[available_gas(3000000)]
fn test_transfer_lt_total_balance() {
    let token = deploy('Governor Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 45);
    assert(token.balanceOf(get_contract_address()) == 12300, 'remaining');
    assert(token.balanceOf(recipient) == 45, '45 transferred');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_INSUFFICIENT_BALANCE', 'ENTRYPOINT_FAILED'))]
fn test_transfer_gt_total_balance() {
    let token = deploy('Governor Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, 12346);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_AMOUNT_OVERFLOW', 'ENTRYPOINT_FAILED'))]
fn test_transfer_overflow() {
    let token = deploy('Governor Token', 'GT', 12345);

    let recipient = contract_address_const::<12345>();
    token.transfer(recipient, u256 { high: 1, low: 0 });
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_same() {
    let token = deploy('Governor Token', 'GT', 12345);

    token.get_average_delegated(contract_address_const::<12345>(), 0, 0);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_backwards() {
    let token = deploy('Governor Token', 'GT', 12345);

    token.get_average_delegated(contract_address_const::<12345>(), 1, 0);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future() {
    let token = deploy('Governor Token', 'GT', 12345);

    token.get_average_delegated(contract_address_const::<12345>(), 0, 1);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future_non_zero() {
    let token = deploy('Governor Token', 'GT', 12345);

    set_block_timestamp(5);

    token.get_average_delegated(contract_address_const::<12345>(), 4, 6);
}

#[test]
#[available_gas(3000000)]
fn test_approve_sets_allowance() {
    let token = deploy('Governor Token', 'GT', 12345);

    let spender = contract_address_const::<12345>();
    token.approve(spender, 5151);
    assert(token.allowance(get_contract_address(), spender) == 5151, 'allowance');
}

#[test]
#[available_gas(3000000)]
fn test_approve_allows_transfer_from() {
    let token = deploy('Governor Token', 'GT', 12345);

    let owner = get_contract_address();
    let spender = contract_address_const::<12345>();
    let recipient = contract_address_const::<12346>();
    token.approve(spender, 12345);
    set_contract_address(spender);

    assert(token.transfer_from(owner, recipient, 12345), 'transfer_from');
    assert(token.balanceOf(owner) == 0, 'balanceOf(from)');
    assert(token.balanceOf(recipient) == 12345, 'balanceOf(to)');
    assert(token.balanceOf(spender) == 0, 'balanceOf(spender)');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TRANSFER_FROM_ALLOWANCE', 'ENTRYPOINT_FAILED'))]
fn test_transfer_from_insufficient_allowance() {
    let token = deploy('Governor Token', 'GT', 12345);

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
    let token = deploy('Governor Token', 'GT', 12345);

    let spender = contract_address_const::<12345>();
    let recipient = contract_address_const::<12346>();
    token.approve(spender, u256 { high: 1, low: 0 });
}

#[test]
#[available_gas(30000000)]
fn test_delegate_count_lags() {
    let token = deploy('Governor Token', 'GT', 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);

    assert(token.get_delegated_at(delegatee, 1) == 0, 'b second before');
    assert(token.get_delegated_at(delegatee, 2) == 0, 'b second of');
    token.delegate(delegatee);
    assert(token.get_delegated_at(delegatee, 1) == 0, 'a second of');
    assert(token.get_delegated_at(delegatee, 2) == 0, 'a second of');

    set_block_timestamp(4);

    assert(token.get_delegated_at(delegatee, 3) == 12345, 'a second after');
    assert(token.get_delegated_at(delegatee, 4) == 12345, 'a 2 seconds after');
}


#[test]
#[available_gas(30000000)]
fn test_get_delegated_cumulative() {
    let token = deploy('Governor Token', 'GT', 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    token.delegate(delegatee);
    set_block_timestamp(4);

    assert(token.get_delegated_cumulative(delegatee, 1) == 0, 'second before');
    assert(token.get_delegated_cumulative(delegatee, 2) == 0, 'second of');
    assert(token.get_delegated_cumulative(delegatee, 3) == 12345, 'second after');
    assert(token.get_delegated_cumulative(delegatee, 4) == 24690, '2 seconds after');
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future() {
    let token = deploy('Governor Token', 'GT', 12345);

    token.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future_non_zero_ts() {
    let token = deploy('Governor Token', 'GT', 12345);

    set_block_timestamp(5);

    token.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future() {
    let token = deploy('Governor Token', 'GT', 12345);

    token.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future_non_zero_ts() {
    let token = deploy('Governor Token', 'GT', 12345);

    set_block_timestamp(5);

    token.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
#[available_gas(30000000)]
fn test_get_average_delegated() {
    let token = deploy('Governor Token', 'GT', 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(10);

    assert(token.get_average_delegated(delegatee, 1, 2) == 0, '1-2');
    assert(token.get_average_delegated(delegatee, 2, 3) == 0, '2-3');
    assert(token.get_average_delegated(delegatee, 3, 4) == 0, '3-4');
    assert(token.get_average_delegated(delegatee, 4, 5) == 0, '4-5');
    assert(token.get_average_delegated(delegatee, 4, 10) == 0, '4-10');
    assert(token.get_average_delegated(delegatee, 0, 10) == 0, '4-10');

    // rewind to delegate at ts 2
    set_block_timestamp(2);
    token.delegate(delegatee);
    set_block_timestamp(10);

    assert(token.get_average_delegated(delegatee, 1, 2) == 0, '1-2 after');
    assert(token.get_average_delegated(delegatee, 2, 3) == 12345, '2-3 after');
    assert(token.get_average_delegated(delegatee, 3, 4) == 12345, '3-4 after');
    assert(token.get_average_delegated(delegatee, 4, 5) == 12345, '4-5 after');
    assert(token.get_average_delegated(delegatee, 4, 10) == 12345, '4-10 after');

    // rewind to undelegate at 8
    set_block_timestamp(8);
    token.delegate(contract_address_const::<0>());

    set_block_timestamp(12);
    assert(token.get_average_delegated(delegatee, 4, 10) == 8230, 'average (4 sec * 12345)/6');
}


#[test]
#[available_gas(30000000)]
fn test_transfer_delegates_moved() {
    let token = deploy('Governor Token', 'GT', 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    token.delegate(delegatee);

    token.transfer(contract_address_const::<3456>(), 500);
    set_block_timestamp(5);

    assert(token.get_delegated(delegatee) == (12345 - 500), 'delegated');
    assert(
        token.get_average_delegated(delegatee, 0, 5) == ((3 * (12345 - 500)) / 5),
        'average 3/5 seconds'
    );
}


#[test]
#[available_gas(30000000)]
fn test_delegate_undelegate() {
    let token = deploy('Governor Token', 'GT', 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    token.delegate(delegatee);

    set_block_timestamp(5);
    token.delegate(Zeroable::zero());
    set_block_timestamp(8);

    assert(token.get_delegated(delegatee) == 0, 'delegated');
    assert(token.get_average_delegated(delegatee, 0, 8) == ((3 * 12345) / 8), 'average');
}
