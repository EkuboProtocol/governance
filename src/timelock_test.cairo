use core::array::{Array, ArrayTrait, SpanTrait};
use governance::execution_state::{ExecutionState};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::test::test_token::{deploy as deploy_token};
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait, Timelock, Config};
use starknet::account::{Call};
use starknet::{
    get_contract_address, syscalls::{deploy_syscall}, ClassHash, contract_address_const,
    ContractAddress, get_block_timestamp, testing::set_block_timestamp
};

pub(crate) fn deploy(owner: ContractAddress, delay: u64, window: u64) -> ITimelockDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(owner, delay, window), ref constructor_args);

    let (address, _) = deploy_syscall(
        Timelock::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_FAILED');
    return ITimelockDispatcher { contract_address: address };
}

#[test]
fn test_deploy() {
    let timelock = deploy(contract_address_const::<2300>(), 10239, 3600);

    let configuration = timelock.get_config();
    assert(configuration.delay == 10239, 'delay');
    assert(configuration.window == 3600, 'window');
    let owner = timelock.get_owner();
    assert(owner == contract_address_const::<2300>(), 'owner');
}

pub(crate) fn transfer_call(
    token: IERC20Dispatcher, recipient: ContractAddress, amount: u256
) -> Call {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(recipient, amount), ref calldata);

    Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata.span()
    }
}

pub(crate) fn single_call(call: Call) -> Span<Call> {
    return array![call].span();
}

#[test]
fn test_queue_execute() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token(get_contract_address(), 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let execution_window = timelock.get_execution_window(id);
    assert(execution_window.earliest == 86401, 'earliest');
    assert(execution_window.latest == 90001, 'latest');

    set_block_timestamp(86401);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
    assert(token.balanceOf(recipient) == 500_u256, 'balance');
}

#[test]
#[should_panic(expected: ('HAS_BEEN_CANCELED', 'ENTRYPOINT_FAILED'))]
fn test_queue_cancel() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token(get_contract_address(), 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    set_block_timestamp(86401);
    timelock.cancel(id);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_queue_execute_twice() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token(get_contract_address(), 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    set_block_timestamp(86401);

    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[should_panic(expected: ('TOO_EARLY', 'ENTRYPOINT_FAILED'))]
fn test_queue_executed_too_early() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token(get_contract_address(), 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let execution_window = timelock.get_execution_window(id);
    set_block_timestamp(execution_window.earliest - 1);
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}

#[test]
#[should_panic(expected: ('TOO_LATE', 'ENTRYPOINT_FAILED'))]
fn test_queue_executed_too_late() {
    set_block_timestamp(1);
    let timelock = deploy(get_contract_address(), 86400, 3600);

    let token = deploy_token(get_contract_address(), 12345);
    token.transfer(timelock.contract_address, 12345);

    let recipient = contract_address_const::<12345>();

    let id = timelock.queue(single_call(transfer_call(token, recipient, 500_u256)));

    let execution_window = timelock.get_execution_window(id);
    set_block_timestamp(execution_window.latest);
    timelock.execute(single_call(transfer_call(token, recipient, 500_u256)));
}
