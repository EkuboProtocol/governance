use core::num::traits::zero::{Zero};
use governance::execution_state_test::{assert_pack_unpack};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker_v2::{
    IStakerV2Dispatcher, IStakerV2DispatcherTrait, Staker,
    Staker::{DelegatedSnapshot, DelegatedSnapshotStorePacking},
};

use governance::test::test_token::{TestToken, deploy as deploy_token};
use starknet::testing::{pop_log, set_block_timestamp};
use starknet::{contract_address_const, get_contract_address, syscalls::deploy_syscall};

pub(crate) fn setup(amount: u256) -> (IStakerV2Dispatcher, IERC20Dispatcher) {
    let token = deploy_token(get_contract_address(), amount);
    let (staker_address, _) = deploy_syscall(
        Staker::TEST_CLASS_HASH.try_into().unwrap(),
        0,
        array![token.contract_address.into()].span(),
        true,
    )
        .expect('DEPLOY_TK_FAILED');
    return (IStakerV2Dispatcher { contract_address: staker_address }, token);
}

mod stake_withdraw {
    use super::{
        IERC20DispatcherTrait, IStakerV2DispatcherTrait, Staker, TestToken, Zero,
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

mod staker_staked_seconds_per_total_staked_calculation {
    use starknet::{get_caller_address};

    use super::{
        IERC20DispatcherTrait, IStakerV2DispatcherTrait, contract_address_const, set_block_timestamp,
        setup,
    };

    #[test]
    fn test_should_return_0_if_no_data_found() {
        let (staker, _) = setup(10000);

        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(0), u256 { high: 0, low: 0_u128.into() },
        );
        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(1000), u256 { high: 0, low: 0_u128.into() },
        );
    }

    #[test]
    #[should_panic(expected: ('INSUFFICIENT_AMOUNT_STAKED', 'ENTRYPOINT_FAILED'))]
    fn test_raises_error_if_no_history_exists_and_withdrawal_happens() {
        // TODO(biatcode): This test accidentally tests other
        // functionality and should be refactored

        let (staker, token) = setup(10000);

        // Caller is token owner
        let token_owner = get_caller_address();

        // Adress to delegate tokens to
        let delegatee = contract_address_const::<1234567890>();

        token.approve(staker.contract_address, 10000);

        set_block_timestamp(1);
        staker.stake_amount(delegatee, 1000);
        set_block_timestamp(2);
        staker.withdraw_amount(delegatee, token_owner, 500);
        set_block_timestamp(3);
        staker.stake_amount(delegatee, 1000);
        set_block_timestamp(4);
        staker.withdraw_amount(delegatee, token_owner, 2000);
    }

    #[test]
    fn test_check_total_staked_calculations() {
        let (staker, token) = setup(1000);

        // Caller is token owner
        let delegatee = contract_address_const::<1234567890>();

        assert_eq!(staker.get_total_staked_at(0), 0);
        assert_eq!(staker.get_total_staked_at(100), 0);

        set_block_timestamp(10);
        token.approve(staker.contract_address, 100);
        staker.stake(delegatee);

        set_block_timestamp(15);
        token.approve(staker.contract_address, 300);
        staker.stake(delegatee);

        set_block_timestamp(20);
        token.approve(staker.contract_address, 200);
        staker.stake(delegatee);

        set_block_timestamp(40);
        token.approve(staker.contract_address, 100);
        staker.stake(delegatee);

        set_block_timestamp(65);
        token.approve(staker.contract_address, 300);
        staker.stake(delegatee);

        assert_eq!(staker.get_total_staked_at(0), 0);
        assert_eq!(staker.get_total_staked_at(5), 0);
        assert_eq!(staker.get_total_staked_at(9), 0);
        assert_eq!(staker.get_total_staked_at(10), 100);
        assert_eq!(staker.get_total_staked_at(11), 100);
        assert_eq!(staker.get_total_staked_at(14), 100);
        assert_eq!(staker.get_total_staked_at(15), 400);
        assert_eq!(staker.get_total_staked_at(19), 400);
        assert_eq!(staker.get_total_staked_at(20), 600);
        assert_eq!(staker.get_total_staked_at(30), 600);
        assert_eq!(staker.get_total_staked_at(39), 600);
        assert_eq!(staker.get_total_staked_at(40), 700);
        assert_eq!(staker.get_total_staked_at(64), 700);
        assert_eq!(staker.get_total_staked_at(65), 1000);
        assert_eq!(staker.get_total_staked_at(100), 1000);
    }

    #[test]
    fn test_get_time_weighted_total_staked_sum_at() {
        let (staker, token) = setup(1000);

        // Caller is token owner
        let token_owner = get_caller_address();
        let delegatee = contract_address_const::<1234567890>();

        assert_eq!(staker.get_time_weighted_total_staked_sum_at(0), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(100), 0);

        set_block_timestamp(10);
        token.approve(staker.contract_address, 100);
        staker.stake(delegatee);

        assert_eq!(staker.get_time_weighted_total_staked_sum_at(0), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(9), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(10), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(11), 100);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(12), 200);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(13), 300);

        set_block_timestamp(15);
        token.approve(staker.contract_address, 300);
        staker.stake(delegatee);

        set_block_timestamp(20);
        token.approve(staker.contract_address, 200);
        staker.stake(delegatee);

        set_block_timestamp(40);
        token.approve(staker.contract_address, 100);
        staker.stake(delegatee);

        set_block_timestamp(65);
        token.approve(staker.contract_address, 300);
        staker.stake(delegatee);

        set_block_timestamp(70);

        staker.withdraw(delegatee, token_owner);

        assert_eq!(staker.get_time_weighted_total_staked_sum_at(0), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(5), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(9), 0);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(10), 0); // 100/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(11), 100);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(14), 400);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(15), 500); // 400/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(19), 2100);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(20), 2500); // 600/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(30), 8500);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(39), 13900);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(40), 14500); // 700/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(64), 31300);
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(65), 32000); // 1000/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(70), 37000); // 0/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(100), 37000); // 0/s
        assert_eq!(staker.get_time_weighted_total_staked_sum_at(200), 37000); // 0/s
    }

    #[test]
    fn test_should_stake_10000_tokens_for_5_seconds_adding_10000_every_second_to_staked_seconds() {
        let (staker, token) = setup(1000);

        // Caller is token owner
        let token_owner = get_caller_address();
        let delegatee = contract_address_const::<1234567890>();

        set_block_timestamp(10);
        token.approve(staker.contract_address, 10);
        staker.stake(delegatee);

        set_block_timestamp(15);
        token.approve(staker.contract_address, 10);
        staker.stake(delegatee);

        set_block_timestamp(20);
        staker.withdraw(delegatee, token_owner);

        set_block_timestamp(30);
        token.approve(staker.contract_address, 30);
        staker.stake(delegatee);

        set_block_timestamp(40);
        staker.withdraw(delegatee, token_owner);

        assert_eq!(staker.get_seconds_per_total_staked_sum_at(0), 0);
        assert_eq!(staker.get_seconds_per_total_staked_sum_at(10), 0);
        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(15),
            u256 { low: 0x80000000000000000000000000000000_u128, high: 0_u128 },
        ); // 1/2
        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(20),
            u256 { low: 0xC0000000000000000000000000000000, high: 0_u128 },
        ); // 3/4
        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(30),
            u256 { low: 0xC0000000000000000000000000000000, high: 0_u128 },
        ); // 3/4
        assert_eq!(
            staker.get_seconds_per_total_staked_sum_at(40),
            u256 { low: 0x15555555555555555555555555555555, high: 1_u128 },
        ); // 1 + 1/12
    }
}
