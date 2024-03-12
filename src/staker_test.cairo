use core::array::{ArrayTrait};
use core::num::traits::zero::{Zero};
use core::option::{OptionTrait};
use core::result::{Result, ResultTrait};
use core::traits::{TryInto};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::airdrop_test::{deploy_token};

use governance::staker::{
    IStakerDispatcher, IStakerDispatcherTrait, Staker,
    Staker::{DelegatedSnapshotStorePacking, DelegatedSnapshot},
};
use starknet::testing::{set_contract_address, set_block_timestamp, pop_log};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress,
};

pub fn setup(owner: ContractAddress, amount: u128) -> (IStakerDispatcher, IERC20Dispatcher) {
    let token = deploy_token(owner, amount);
    let (staker_address, _) = deploy_syscall(
        Staker::TEST_CLASS_HASH.try_into().unwrap(),
        0,
        array![token.contract_address.into()].span(),
        true
    )
        .expect('DEPLOY_TK_FAILED');
    return (IStakerDispatcher { contract_address: staker_address }, token);
}

#[test]
fn test_governance_token_delegated_snapshot_store_pack() {
    assert(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 0, delegated_cumulative: 0 }
        ) == 0,
        'zero'
    );
    assert(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 0, delegated_cumulative: 1 }
        ) == 1,
        'one cumulative'
    );
    assert(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 1, delegated_cumulative: 0 }
        ) == 0x1000000000000000000000000000000000000000000000000,
        'one timestamp'
    );
    assert(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 1, delegated_cumulative: 1 }
        ) == 0x1000000000000000000000000000000000000000000000001,
        'one both'
    );

    assert(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot {
                timestamp: 576460752303423488, // this timestamp equal to 2**59 is so large it's invalid
                delegated_cumulative: 6277101735386680763835789423207666416102355444464034512895 // max u192
            }
        ) == 3618502788666131113263695016908177884250476444008934042335404944711319814143,
        'very large values'
    );
}

#[test]
fn test_governance_token_delegated_snapshot_store_unpack() {
    assert(
        DelegatedSnapshotStorePacking::unpack(
            0
        ) == DelegatedSnapshot { timestamp: 0, delegated_cumulative: 0 },
        'zero'
    );
    assert(
        DelegatedSnapshotStorePacking::unpack(
            1
        ) == DelegatedSnapshot { timestamp: 0, delegated_cumulative: 1 },
        'one cumulative'
    );
    assert(
        DelegatedSnapshotStorePacking::unpack(
            0x1000000000000000000000000000000000000000000000000
        ) == DelegatedSnapshot { timestamp: 1, delegated_cumulative: 0 },
        'one timestamp'
    );
    assert(
        DelegatedSnapshotStorePacking::unpack(
            0x1000000000000000000000000000000000000000000000001
        ) == DelegatedSnapshot { timestamp: 1, delegated_cumulative: 1 },
        'one both'
    );

    assert(
        DelegatedSnapshotStorePacking::unpack(
            3618502788666131113263695016908177884250476444008934042335404944711319814143
        ) == DelegatedSnapshot {
            timestamp: 576460752303423488,
            delegated_cumulative: 6277101735386680763835789423207666416102355444464034512895
        },
        'max both'
    );
}

#[test]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_same() {
    let (staker, _) = setup(get_contract_address(), 12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 0, 0);
}

#[test]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_backwards() {
    let (staker, _) = setup(get_contract_address(), 12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 1, 0);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future() {
    let (staker, _) = setup(get_contract_address(), 12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 0, 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future_non_zero() {
    let (staker, _) = setup(get_contract_address(), 12345);

    set_block_timestamp(5);

    staker.get_average_delegated(contract_address_const::<12345>(), 4, 6);
}

#[test]
fn test_approve_sets_allowance() {
    let (_, erc20) = setup(get_contract_address(), 12345);

    let spender = contract_address_const::<12345>();
    erc20.approve(spender, 5151);
    assert(erc20.allowance(get_contract_address(), spender) == 5151, 'allowance');
}


#[test]
fn test_delegate_count_lags() {
    let (staker, _) = setup(get_contract_address(), 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);

    assert(staker.get_delegated_at(delegatee, 1) == 0, 'b second before');
    assert(staker.get_delegated_at(delegatee, 2) == 0, 'b second of');
    staker.delegate(delegatee);
    assert(staker.get_delegated_at(delegatee, 1) == 0, 'a second of');
    assert(staker.get_delegated_at(delegatee, 2) == 0, 'a second of');

    set_block_timestamp(4);

    assert(staker.get_delegated_at(delegatee, 3) == 12345, 'a second after');
    assert(staker.get_delegated_at(delegatee, 4) == 12345, 'a 2 seconds after');
}


#[test]
fn test_get_delegated_cumulative() {
    let (staker, _) = setup(get_contract_address(), 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    staker.delegate(delegatee);
    set_block_timestamp(4);

    assert(staker.get_delegated_cumulative(delegatee, 1) == 0, 'second before');
    assert(staker.get_delegated_cumulative(delegatee, 2) == 0, 'second of');
    assert(staker.get_delegated_cumulative(delegatee, 3) == 12345, 'second after');
    assert(staker.get_delegated_cumulative(delegatee, 4) == 24690, '2 seconds after');
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future() {
    let (staker, _) = setup(get_contract_address(), 12345);

    staker.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future_non_zero_ts() {
    let (staker, _) = setup(get_contract_address(), 12345);

    set_block_timestamp(5);

    staker.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future() {
    let (staker, _) = setup(get_contract_address(), 12345);

    staker.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future_non_zero_ts() {
    let (staker, _) = setup(get_contract_address(), 12345);

    set_block_timestamp(5);

    staker.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
fn test_get_average_delegated() {
    let (staker, _) = setup(get_contract_address(), 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(10);

    assert(staker.get_average_delegated(delegatee, 1, 2) == 0, '1-2');
    assert(staker.get_average_delegated(delegatee, 2, 3) == 0, '2-3');
    assert(staker.get_average_delegated(delegatee, 3, 4) == 0, '3-4');
    assert(staker.get_average_delegated(delegatee, 4, 5) == 0, '4-5');
    assert(staker.get_average_delegated(delegatee, 4, 10) == 0, '4-10');
    assert(staker.get_average_delegated(delegatee, 0, 10) == 0, '4-10');

    // rewind to delegate at ts 2
    set_block_timestamp(2);
    staker.delegate(delegatee);
    set_block_timestamp(10);

    assert(staker.get_average_delegated(delegatee, 1, 2) == 0, '1-2 after');
    assert(staker.get_average_delegated(delegatee, 2, 3) == 12345, '2-3 after');
    assert(staker.get_average_delegated(delegatee, 3, 4) == 12345, '3-4 after');
    assert(staker.get_average_delegated(delegatee, 4, 5) == 12345, '4-5 after');
    assert(staker.get_average_delegated(delegatee, 4, 10) == 12345, '4-10 after');

    // rewind to undelegate at 8
    set_block_timestamp(8);
    staker.delegate(contract_address_const::<0>());

    set_block_timestamp(12);
    assert(staker.get_average_delegated(delegatee, 4, 10) == 8230, 'average (4 sec * 12345)/6');
}


#[test]
fn test_transfer_delegates_moved() {
    let (staker, token) = setup(get_contract_address(), 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    staker.delegate(delegatee);

    token.transfer(contract_address_const::<3456>(), 500);
    set_block_timestamp(5);

    assert(staker.get_delegated(delegatee) == (12345 - 500), 'delegated');
    assert(
        staker.get_average_delegated(delegatee, 0, 5) == ((3 * (12345 - 500)) / 5),
        'average 3/5 seconds'
    );
}


#[test]
fn test_delegate_undelegate() {
    let (staker, token) = setup(get_contract_address(), 12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    staker.delegate(delegatee);

    set_block_timestamp(5);
    staker.delegate(Zero::zero());
    set_block_timestamp(8);

    assert(staker.get_delegated(delegatee) == 0, 'delegated');
    assert(staker.get_average_delegated(delegatee, 0, 8) == ((3 * 12345) / 8), 'average');

    assert(staker.get_delegated_at(delegatee, timestamp: 1) == 0, 'at 1');
    assert(staker.get_delegated_at(delegatee, timestamp: 2) == 0, 'at 2');
    assert(staker.get_delegated_at(delegatee, timestamp: 3) == 12345, 'at 3');
    assert(staker.get_delegated_at(delegatee, timestamp: 4) == 12345, 'at 4');
    assert(staker.get_delegated_at(delegatee, timestamp: 5) == 12345, 'at 5');
    assert(staker.get_delegated_at(delegatee, timestamp: 6) == 0, 'at 6');
}
