use array::{Array, ArrayTrait, SpanTrait};
use debug::PrintTrait;
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait, Timelock};
use governance::tests::token_test::{deploy as deploy_token};
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
    get_block_timestamp, testing::set_block_timestamp
};
use starknet::class_hash::Felt252TryIntoClassHash;
use starknet::account::{Call};
use traits::{TryInto};
use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy(owner: ContractAddress, delay: u64, window: u64) -> ITimelockDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@owner, ref constructor_args);
    Serde::serialize(@delay, ref constructor_args);
    Serde::serialize(@window, ref constructor_args);

    let (address, _) = deploy_syscall(
        Timelock::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_FAILED');
    return ITimelockDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_deploy() {
    let timelock = deploy(contract_address_const::<2300>(), 10239, 3600);

    let (window, delay) = timelock.get_configuration();
    assert(window == 10239, 'window');
    assert(delay == 3600, 'delay');
    let owner = timelock.get_owner();
    assert(owner == contract_address_const::<2300>(), 'owner');
}

fn transfer_call(token: ITokenDispatcher, recipient: ContractAddress, amount: u256) -> Call {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@recipient, ref calldata);
    Serde::serialize(@amount, ref calldata);

    Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata
    }
}

fn single_call(call: Call) -> Span<Call> {
    let mut calls: Array<Call> = ArrayTrait::new();
    calls.append(call);
    return calls.span();
}

#[test]
#[available_gas(30000000)]
fn test_queue_execute() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token('TIMELOCK', 'TL', 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let (earliest, latest) = timelock.get_execution_window(id);
    assert(earliest == 86401, 'earliest');
    assert(latest == 90001, 'latest');

    set_block_timestamp(86401);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
    assert(token.balance_of(recipient) == 500_u256, 'balance');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('DOES_NOT_EXIST', 'ENTRYPOINT_FAILED'))]
fn test_queue_cancel() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token('TIMELOCK', 'TL', 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    set_block_timestamp(86401);
    timelock.cancel(id);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_queue_execute_twice() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token('TIMELOCK', 'TL', 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    set_block_timestamp(86401);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[available_gas(30000000)]
#[should_panic(expected: ('TOO_EARLY', 'ENTRYPOINT_FAILED'))]
fn test_queue_executed_too_early() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token('TIMELOCK', 'TL', 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let (earliest, latest) = timelock.get_execution_window(id);
    set_block_timestamp(earliest - 1);
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('TOO_LATE', 'ENTRYPOINT_FAILED'))]
fn test_queue_executed_too_late() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token('TIMELOCK', 'TL', 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let (earliest, latest) = timelock.get_execution_window(id);
    set_block_timestamp(latest);
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}
