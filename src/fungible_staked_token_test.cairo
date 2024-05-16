use core::array::SpanTrait;
use core::array::{ArrayTrait};
use core::num::traits::zero::{Zero};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::serde::Serde;
use core::traits::{TryInto};

use governance::execution_state::{ExecutionState};
use governance::fungible_staked_token::{
    IFungibleStakedToken, IFungibleStakedTokenDispatcher, IFungibleStakedTokenDispatcherTrait,
    FungibleStakedToken
};
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


fn deploy(staker: IStakerDispatcher) -> IFungibleStakedTokenDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(staker), ref constructor_args);

    let (address, _) = deploy_syscall(
        FungibleStakedToken::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IFungibleStakedTokenDispatcher { contract_address: address };
}

fn setup() -> (IStakerDispatcher, IERC20Dispatcher, IFungibleStakedTokenDispatcher) {
    let (staker, token) = setup_staker(1000000);
    let fungible_staked_token = deploy(staker);

    (staker, token, fungible_staked_token)
}


#[test]
fn test_setup() {
    let (staker, token, fst) = setup();

    assert_eq!(fst.get_staker(), staker.contract_address);
    assert_eq!(
        IStakerDispatcher { contract_address: fst.get_staker() }.get_token(), token.contract_address
    );
}


#[test]
fn test_deposit() {
    let (staker, token, fst) = setup();
    token.approve(fst.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    fst.delegate(delegatee);
    fst.deposit();
    assert_eq!(staker.get_delegated(delegatee), 100);
    assert_eq!(
        IERC20Dispatcher { contract_address: fst.contract_address }
            .balanceOf(get_contract_address()),
        100
    );
}

#[test]
fn test_deposit_then_transfer() {
    let (staker, token, fst) = setup();
    token.approve(fst.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    let recipient = contract_address_const::<'recipient'>();
    fst.delegate(delegatee);
    fst.deposit();
    IERC20Dispatcher { contract_address: fst.contract_address }.transfer(recipient, 75);
    assert_eq!(staker.get_delegated(delegatee), 25);
    assert_eq!(staker.get_delegated(Zero::zero()), 75);
}

#[test]
fn test_deposit_then_delegate() {
    let (staker, token, fst) = setup();
    token.approve(fst.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    fst.deposit();
    assert_eq!(staker.get_delegated(Zero::zero()), 100);
    assert_eq!(staker.get_delegated(delegatee), 0);

    fst.delegate(delegatee);
    assert_eq!(staker.get_delegated(Zero::zero()), 0);
    assert_eq!(staker.get_delegated(delegatee), 100);
}

#[test]
fn test_withdraw() {
    let (staker, token, fst) = setup();
    token.approve(fst.contract_address, 100);
    let delegatee = contract_address_const::<'delegate'>();
    fst.delegate(delegatee);
    fst.deposit();
    fst.withdraw();
    assert_eq!(staker.get_delegated(delegatee), 0);
    assert_eq!(staker.get_delegated(Zero::zero()), 0);
}
