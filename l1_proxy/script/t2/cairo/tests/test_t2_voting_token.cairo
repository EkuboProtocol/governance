// EKU-1261 LOCAL snforge tests of the TESTNET-ONLY T2 voting token: fixed supply minted once to the holder, no
// mint/burn/owner/upgrade entry points, ERC20 semantics and the exact selectors the Staker calls. The isolated
// Governor authority on a fixed, fully staked supply is tested with the real Staker/Governor classes in the
// governance package (`src/t2_l1_message_test.cairo`, cfg(test)).
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet::syscalls::call_contract_syscall;
use t2_voting_token::T2VotingToken::{Event as TokenEvent, Transfer};
use t2_voting_token::{IT2VotingTokenDispatcher, IT2VotingTokenDispatcherTrait, TOTAL_SUPPLY};

fn holder() -> ContractAddress {
    't2_starknet'.try_into().unwrap()
}

fn stranger() -> ContractAddress {
    'third_party'.try_into().unwrap()
}

fn deploy_token() -> IT2VotingTokenDispatcher {
    let (address, _) = declare("T2VotingToken")
        .unwrap()
        .contract_class()
        .deploy(@array![holder().into()])
        .unwrap();
    IT2VotingTokenDispatcher { contract_address: address }
}

#[test]
fn test_fixed_supply_minted_once_to_holder() {
    let mut spy = spy_events();
    let token = deploy_token();
    assert_eq!(token.totalSupply(), TOTAL_SUPPLY);
    assert_eq!(token.balanceOf(holder()), TOTAL_SUPPLY);
    assert_eq!(token.balanceOf(stranger()), 0);
    assert_eq!(token.decimals(), 18);
    spy
        .assert_emitted(
            @array![
                (
                    token.contract_address,
                    TokenEvent::Transfer(
                        Transfer { from: 0.try_into().unwrap(), to: holder(), value: TOTAL_SUPPLY },
                    ),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'ZERO_HOLDER')]
fn test_zero_holder_refused() {
    let class = declare("T2VotingToken").unwrap().contract_class();
    match class.deploy(@array![0]) {
        Result::Ok(_) => {},
        Result::Err(e) => panic(e),
    }
}

#[test]
fn test_no_mint_owner_or_upgrade_entry_points() {
    let token = deploy_token();
    let names: Array<felt252> = array![
        selector!("mint"), selector!("burn"), selector!("owner"), selector!("transfer_ownership"),
        selector!("transferOwnership"), selector!("upgrade"), selector!("set_balance"), selector!("pause"),
    ];
    for s in names {
        let r = call_contract_syscall(token.contract_address, s, array![holder().into(), 1, 0].span());
        assert(r.is_err(), 'unexpected entry point');
    }
    assert_eq!(token.totalSupply(), TOTAL_SUPPLY);
}

#[test]
fn test_transfer_and_allowance_semantics() {
    let token = deploy_token();
    start_cheat_caller_address(token.contract_address, holder());
    assert(token.transfer(stranger(), 5), 'transfer');
    assert(token.approve(stranger(), 7), 'approve');
    stop_cheat_caller_address(token.contract_address);
    assert_eq!(token.balanceOf(stranger()), 5);
    assert_eq!(token.allowance(holder(), stranger()), 7);
    start_cheat_caller_address(token.contract_address, stranger());
    assert(token.transferFrom(holder(), stranger(), 7), 'transferFrom');
    stop_cheat_caller_address(token.contract_address);
    assert_eq!(token.allowance(holder(), stranger()), 0);
    assert_eq!(token.balanceOf(stranger()), 12);
    assert_eq!(token.balanceOf(holder()) + token.balanceOf(stranger()), TOTAL_SUPPLY);
}

#[test]
#[should_panic(expected: 'INSUFFICIENT_BALANCE')]
fn test_transfer_above_balance_refused() {
    let token = deploy_token();
    start_cheat_caller_address(token.contract_address, stranger());
    token.transfer(holder(), 1);
}

#[test]
#[should_panic(expected: 'INSUFFICIENT_ALLOWANCE')]
fn test_transfer_from_without_allowance_refused() {
    let token = deploy_token();
    start_cheat_caller_address(token.contract_address, stranger());
    token.transferFrom(holder(), stranger(), 1);
}

#[test]
fn test_exposes_the_erc20_selectors_the_staker_calls() {
    // governance::staker::Staker calls transferFrom (stake) and transfer (withdraw) through the camelCase IERC20.
    let token = deploy_token();
    start_cheat_caller_address(token.contract_address, holder());
    token.approve(stranger(), 3);
    stop_cheat_caller_address(token.contract_address);
    start_cheat_caller_address(token.contract_address, stranger());
    let r = call_contract_syscall(
        token.contract_address, selector!("transferFrom"), array![holder().into(), stranger().into(), 3, 0].span(),
    );
    assert(r.unwrap() == array![1].span(), 'transferFrom selector');
    let r = call_contract_syscall(token.contract_address, selector!("transfer"), array![holder().into(), 1, 0].span());
    assert(r.unwrap() == array![1].span(), 'transfer selector');
    stop_cheat_caller_address(token.contract_address);
}
