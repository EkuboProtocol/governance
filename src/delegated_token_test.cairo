use core::array::SpanTrait;
use core::array::{ArrayTrait};
use core::num::traits::zero::{Zero};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::serde::Serde;
use core::traits::{TryInto};
use governance::delegated_token::{
    IDelegatedToken, IDelegatedTokenDispatcher, IDelegatedTokenDispatcherTrait, DelegatedToken
};

use governance::execution_state::{ExecutionState};
use governance::governor_test::{advance_time};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
use governance::staker_test::{setup as setup_staker};
use starknet::account::{Call};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress, get_block_timestamp,
    testing::{set_block_timestamp, set_contract_address, pop_log}
};


fn deploy(staker: IStakerDispatcher, name: felt252, symbol: felt252) -> IDelegatedTokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(staker, name, symbol), ref constructor_args);

    let (address, _) = deploy_syscall(
        DelegatedToken::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IDelegatedTokenDispatcher { contract_address: address };
}

fn setup() -> (IStakerDispatcher, IERC20Dispatcher, IDelegatedTokenDispatcher) {
    let (staker, token) = setup_staker(1000000);
    let delegated_token = deploy(staker, 'Staked Token', 'vSTT');

    (staker, token, delegated_token)
}


#[test]
fn test_setup() {
    let (staker, token, dt) = setup();

    assert_eq!(dt.get_staker(), staker.contract_address);
    assert_eq!(
        IStakerDispatcher { contract_address: dt.get_staker() }.get_token(), token.contract_address
    );
}


#[test]
fn test_deposit() {
    let (staker, token, dt) = setup();
    token.approve(dt.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    dt.delegate(delegatee);
    dt.deposit();
    assert_eq!(staker.get_delegated(delegatee), 100);
    assert_eq!(
        IERC20Dispatcher { contract_address: dt.contract_address }
            .balanceOf(get_contract_address()),
        100
    );
    assert_eq!(IERC20Dispatcher { contract_address: dt.contract_address }.totalSupply(), 100);
}

#[test]
fn test_deposit_then_transfer() {
    let (staker, token, dt) = setup();
    token.approve(dt.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    let recipient = contract_address_const::<'recipient'>();
    dt.delegate(delegatee);
    dt.deposit();
    IERC20Dispatcher { contract_address: dt.contract_address }.transfer(recipient, 75);
    assert_eq!(staker.get_delegated(delegatee), 25);
    assert_eq!(staker.get_delegated(Zero::zero()), 75);
    assert_eq!(IERC20Dispatcher { contract_address: dt.contract_address }.totalSupply(), 100);
}

#[test]
fn test_deposit_then_delegate() {
    let (staker, token, dt) = setup();
    token.approve(dt.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    dt.deposit();
    assert_eq!(staker.get_delegated(Zero::zero()), 100);
    assert_eq!(staker.get_delegated(delegatee), 0);

    dt.delegate(delegatee);
    assert_eq!(staker.get_delegated(Zero::zero()), 0);
    assert_eq!(staker.get_delegated(delegatee), 100);
}

#[test]
fn test_withdraw() {
    let (staker, token, dt) = setup();
    token.approve(dt.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    dt.delegate(delegatee);
    dt.deposit();
    dt.withdraw();
    assert_eq!(staker.get_delegated(delegatee), 0);
    assert_eq!(staker.get_delegated(Zero::zero()), 0);
    assert_eq!(IERC20Dispatcher { contract_address: dt.contract_address }.totalSupply(), 0);
}
