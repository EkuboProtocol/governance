use core::num::traits::zero::{Zero};
use governance::execution_state_test::{assert_pack_unpack};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{
    IStakerDispatcher, IStakerDispatcherTrait, Staker,
    Staker::{DelegatedSnapshot, DelegatedSnapshotStorePacking},
};
use governance::test::test_token::{TestToken, deploy as deploy_token};
use starknet::testing::{pop_log, set_block_timestamp};
use starknet::{contract_address_const, get_contract_address, syscalls::deploy_syscall};

pub(crate) fn setup(amount: u256) -> (IStakerDispatcher, IERC20Dispatcher) {
    let token = deploy_token(get_contract_address(), amount);
    let (staker_address, _) = deploy_syscall(
        Staker::TEST_CLASS_HASH.try_into().unwrap(),
        0,
        array![token.contract_address.into()].span(),
        true,
    )
        .expect('DEPLOY_TK_FAILED');
    return (IStakerDispatcher { contract_address: staker_address }, token);
}

mod stake_withdraw {
    use super::{
        IERC20DispatcherTrait, IStakerDispatcherTrait, Staker, TestToken, Zero,
        contract_address_const, get_contract_address, pop_log, setup,
    };

    #[test]
    fn test_takes_approved_token() {
        let (staker, token) = setup(1000);

        token.approve(staker.contract_address, 500);
        staker.stake(contract_address_const::<'delegate'>());

        assert_eq!(
            staker.get_staked(get_contract_address(), contract_address_const::<'delegate'>()), 500,
        );
        assert_eq!(staker.get_staked(get_contract_address(), Zero::zero()), 0);
        assert_eq!(
            staker.get_staked(contract_address_const::<'delegate'>(), get_contract_address()), 0,
        );
        // pop the transfer from 0 to deployer
        pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
        assert_eq!(
            pop_log::<TestToken::Transfer>(token.contract_address),
            Option::Some(
                TestToken::Transfer {
                    from: get_contract_address(), to: staker.contract_address, value: 500,
                },
            ),
        );
        assert_eq!(
            pop_log::<Staker::Staked>(staker.contract_address),
            Option::Some(
                Staker::Staked {
                    from: get_contract_address(),
                    amount: 500,
                    delegate: contract_address_const::<'delegate'>(),
                },
            ),
        );
    }

    #[test]
    #[should_panic(expected: ('ALLOWANCE_OVERFLOW', 'ENTRYPOINT_FAILED'))]
    fn test_fails_allowance_large() {
        let (staker, token) = setup(1000);

        token.approve(staker.contract_address, u256 { high: 1, low: 0 });
        staker.stake(contract_address_const::<'delegate'>());
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_TF_BALANCE', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_fails_insufficient_balance() {
        let (staker, token) = setup(1000);

        token.approve(staker.contract_address, 1001);
        staker.stake(contract_address_const::<'delegate'>());
    }
}

#[test]
fn test_staker_delegated_snapshot_store_pack() {
    assert_eq!(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 0, delegated_cumulative: 0 },
        ),
        0,
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 0, delegated_cumulative: 1 },
        ),
        1,
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 1, delegated_cumulative: 0 },
        ),
        0x1000000000000000000000000000000000000000000000000,
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot { timestamp: 1, delegated_cumulative: 1 },
        ),
        0x1000000000000000000000000000000000000000000000001,
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::pack(
            DelegatedSnapshot {
                timestamp: 576460752303423488,
                delegated_cumulative: 6277101735386680763835789423207666416102355444464034512895,
            },
        ),
        3618502788666131113263695016908177884250476444008934042335404944711319814143,
    );
}

#[test]
fn test_staker_delegated_snapshot_store_unpack() {
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(0),
        DelegatedSnapshot { timestamp: 0, delegated_cumulative: 0 },
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(1),
        DelegatedSnapshot { timestamp: 0, delegated_cumulative: 1 },
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(0x1000000000000000000000000000000000000000000000000),
        DelegatedSnapshot { timestamp: 1, delegated_cumulative: 0 },
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(0x1000000000000000000000000000000000000000000000001),
        DelegatedSnapshot { timestamp: 1, delegated_cumulative: 1 },
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(
            3618502788666131113263695016908177884250476444008934042335404944711319814143,
        ),
        DelegatedSnapshot {
            timestamp: 576460752303423488,
            delegated_cumulative: 6277101735386680763835789423207666416102355444464034512895 // 2**192 - 1
        },
    );
    assert_eq!(
        DelegatedSnapshotStorePacking::unpack(
            // max felt252
            3618502788666131213697322783095070105623107215331596699973092056135872020480,
        ),
        DelegatedSnapshot { timestamp: 576460752303423505, delegated_cumulative: 0 },
    );
}

#[test]
fn test_staker_delegated_snapshot_store_pack_unpack() {
    assert_pack_unpack(DelegatedSnapshot { timestamp: 0, delegated_cumulative: 0 });
    assert_pack_unpack(DelegatedSnapshot { timestamp: 0, delegated_cumulative: 1 });
    assert_pack_unpack(DelegatedSnapshot { timestamp: 1, delegated_cumulative: 0 });
    assert_pack_unpack(DelegatedSnapshot { timestamp: 1, delegated_cumulative: 1 });
    assert_pack_unpack(
        DelegatedSnapshot {
            timestamp: 0,
            delegated_cumulative: 0x1000000000000000000000000000000000000000000000000 - 1,
        },
    );
    assert_pack_unpack(
        DelegatedSnapshot { timestamp: 576460752303423505, delegated_cumulative: 0 },
    );
    assert_pack_unpack(
        DelegatedSnapshot {
            timestamp: 576460752303423504,
            delegated_cumulative: 0x1000000000000000000000000000000000000000000000000 - 1,
        },
    );
}

#[test]
#[should_panic(expected: ('Option::unwrap failed.',))]
fn test_staker_delegated_snapshot_pack_max_timestamp_and_delegated() {
    DelegatedSnapshotStorePacking::pack(
        DelegatedSnapshot { timestamp: 576460752303423505, delegated_cumulative: 1 },
    );
}

#[test]
#[should_panic(expected: ('Option::unwrap failed.',))]
fn test_staker_delegated_snapshot_pack_max_timestamp_plus_one() {
    DelegatedSnapshotStorePacking::pack(
        DelegatedSnapshot { timestamp: 576460752303423506, delegated_cumulative: 0 },
    );
}

#[test]
#[should_panic(expected: ('MAX_DELEGATED_CUMULATIVE',))]
fn test_staker_delegated_snapshot_pack_max_delegated_cumulative() {
    DelegatedSnapshotStorePacking::pack(
        DelegatedSnapshot {
            timestamp: 0, delegated_cumulative: 0x1000000000000000000000000000000000000000000000000,
        },
    );
}

#[test]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_same() {
    let (staker, _) = setup(12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 0, 0);
}

#[test]
#[should_panic(expected: ('ORDER', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_order_backwards() {
    let (staker, _) = setup(12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 1, 0);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future() {
    let (staker, _) = setup(12345);

    staker.get_average_delegated(contract_address_const::<12345>(), 0, 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_average_delegated_future_non_zero() {
    let (staker, _) = setup(12345);

    set_block_timestamp(5);

    staker.get_average_delegated(contract_address_const::<12345>(), 4, 6);
}

#[test]
fn test_approve_sets_allowance() {
    let (_, erc20) = setup(12345);

    let spender = contract_address_const::<12345>();
    erc20.approve(spender, 5151);
    assert(erc20.allowance(get_contract_address(), spender) == 5151, 'allowance');
}

#[test]
fn test_delegate_count_lags() {
    let (staker, token) = setup(12345);
    let delegatee = contract_address_const::<12345>();

    token.approve(staker.contract_address, 12345);

    set_block_timestamp(2);

    assert(staker.get_delegated_at(delegatee, 1) == 0, 'b second before');
    assert(staker.get_delegated_at(delegatee, 2) == 0, 'b second of');
    staker.stake(delegatee);
    assert(staker.get_delegated_at(delegatee, 1) == 0, 'a second of');
    assert(staker.get_delegated_at(delegatee, 2) == 0, 'a second of');

    set_block_timestamp(4);

    assert(staker.get_delegated_at(delegatee, 3) == 12345, 'a second after');
    assert(staker.get_delegated_at(delegatee, 4) == 12345, 'a 2 seconds after');
}

#[test]
fn test_get_delegated_cumulative() {
    let (staker, token) = setup(12345);
    let delegatee = contract_address_const::<12345>();

    token.approve(staker.contract_address, 12345);

    set_block_timestamp(2);

    staker.stake(delegatee);
    set_block_timestamp(4);

    assert(staker.get_delegated_cumulative(delegatee, 1) == 0, 'second before');
    assert(staker.get_delegated_cumulative(delegatee, 2) == 0, 'second of');
    assert(staker.get_delegated_cumulative(delegatee, 3) == 12345, 'second after');
    assert(staker.get_delegated_cumulative(delegatee, 4) == 24690, '2 seconds after');
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future() {
    let (staker, _) = setup(12345);

    staker.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_cumulative_fails_future_non_zero_ts() {
    let (staker, _) = setup(12345);

    set_block_timestamp(5);

    staker.get_delegated_cumulative(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future() {
    let (staker, _) = setup(12345);

    staker.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 1);
}

#[test]
#[should_panic(expected: ('FUTURE', 'ENTRYPOINT_FAILED'))]
fn test_get_delegated_at_fails_future_non_zero_ts() {
    let (staker, _) = setup(12345);

    set_block_timestamp(5);

    staker.get_delegated_at(delegate: contract_address_const::<12345>(), timestamp: 6);
}

#[test]
fn test_get_average_delegated() {
    let (staker, token) = setup(12345);
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
    token.approve(staker.contract_address, 12345);
    staker.stake(delegatee);
    set_block_timestamp(10);

    assert(staker.get_average_delegated(delegatee, 1, 2) == 0, '1-2 after');
    assert(staker.get_average_delegated(delegatee, 2, 3) == 12345, '2-3 after');
    assert(staker.get_average_delegated(delegatee, 3, 4) == 12345, '3-4 after');
    assert(staker.get_average_delegated(delegatee, 4, 5) == 12345, '4-5 after');
    assert(staker.get_average_delegated(delegatee, 4, 10) == 12345, '4-10 after');

    // rewind to undelegate at 8
    set_block_timestamp(8);
    staker.withdraw_amount(delegatee, recipient: contract_address_const::<0>(), amount: 12345);

    set_block_timestamp(12);
    assert(staker.get_average_delegated(delegatee, 4, 10) == 8230, 'average (4 sec * 12345)/6');
}

#[test]
fn test_transfer_delegates_moved() {
    let (staker, token) = setup(12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    token.approve(staker.contract_address, 12345);
    staker.stake(delegatee);
    staker.withdraw_amount(delegatee, contract_address_const::<3456>(), 500);
    set_block_timestamp(5);

    assert_eq!(staker.get_delegated(delegatee), (12345 - 500));
    assert_eq!(staker.get_average_delegated(delegatee, 0, 5), ((3 * (12345 - 500)) / 5));
}

#[test]
fn test_delegate_undelegate() {
    let (staker, token) = setup(12345);
    let delegatee = contract_address_const::<12345>();

    set_block_timestamp(2);
    token.approve(staker.contract_address, 12345);
    staker.stake(delegatee);

    set_block_timestamp(5);
    staker.withdraw_amount(delegatee, Zero::zero(), 12345);
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
