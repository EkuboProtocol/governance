use core::num::traits::zero::{Zero};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::l1_staking_proxy::{
    IL1StakingProxyDispatcher, IL1StakingProxyDispatcherTrait,
    L1StakingProxy, StakingOperation, StakeParams, WithdrawParams,
};
use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait, Staker};
use governance::test::test_token::{TestToken};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address, spy_events, EventSpyAssertionsTrait,
};
use starknet::{ContractAddress, EthAddress, contract_address_const};

fn deploy_test_token() -> IERC20Dispatcher {
    let contract = declare("TestToken").unwrap().contract_class();
    let (contract_address, _) = contract
        .deploy(@array![1000000000000000000000_u256.low.into(), 1000000000000000000000_u256.high.into()])
        .unwrap();
    IERC20Dispatcher { contract_address }
}

fn deploy_staker(token: IERC20Dispatcher) -> IStakerDispatcher {
    let contract = declare("Staker").unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@array![token.contract_address.into()]).unwrap();
    IStakerDispatcher { contract_address }
}

fn deploy_l1_staking_proxy(
    l1_owner: EthAddress, staker: IStakerDispatcher, token: IERC20Dispatcher
) -> IL1StakingProxyDispatcher {
    let contract = declare("L1StakingProxy").unwrap().contract_class();
    let (contract_address, _) = contract
        .deploy(@array![l1_owner.into(), staker.contract_address.into(), token.contract_address.into()])
        .unwrap();
    IL1StakingProxyDispatcher { contract_address }
}

#[test]
fn test_deployment() {
    let token = deploy_test_token();
    let staker = deploy_staker(token);
    let l1_owner: EthAddress = 0x1234567890123456789012345678901234567890_u256.try_into().unwrap();
    
    let proxy = deploy_l1_staking_proxy(l1_owner, staker, token);
    
    assert(proxy.get_l1_owner() == l1_owner, 'Wrong L1 owner');
    assert(proxy.get_staker() == staker.contract_address, 'Wrong staker');
    assert(proxy.get_token() == token.contract_address, 'Wrong token');
}

#[test]
fn test_l1_message_stake() {
    let token = deploy_test_token();
    let staker = deploy_staker(token);
    let l1_owner: EthAddress = 0x1234567890123456789012345678901234567890_u256.try_into().unwrap();
    let proxy = deploy_l1_staking_proxy(l1_owner, staker, token);
    
    // Transfer tokens to the proxy
    let proxy_address = proxy.contract_address;
    let amount = 1000_u128;
    
    start_cheat_caller_address(token.contract_address, contract_address_const::<0>());
    token.transfer(proxy_address, amount.into());
    stop_cheat_caller_address(token.contract_address);
    
    // Approve staker to spend proxy's tokens
    start_cheat_caller_address(token.contract_address, proxy_address);
    token.approve(staker.contract_address, amount.into());
    stop_cheat_caller_address(token.contract_address);
    
    // Create stake operation
    let delegate = contract_address_const::<0x123>();
    let stake_params = StakeParams { delegate, amount };
    let operation = StakingOperation::Stake(stake_params);
    
    // Serialize the operation
    let mut payload = array![];
    Serde::serialize(@operation, ref payload);
    
    // Spy on events
    let mut spy = spy_events();
    
    // Handle L1 message
    proxy.handle_l1_message(l1_owner.into(), payload.span());
    
    // Check that staking happened
    assert(staker.get_staked(proxy_address, delegate) == amount, 'Staking failed');
    assert(staker.get_delegated(delegate) == amount, 'Delegation failed');
    
    // Check events
    spy.assert_emitted(@array![
        (proxy_address, L1StakingProxy::Event::Staked(
            L1StakingProxy::Staked { delegate, amount }
        ))
    ]);
}

#[test]
fn test_l1_message_withdraw() {
    let token = deploy_test_token();
    let staker = deploy_staker(token);
    let l1_owner: EthAddress = 0x1234567890123456789012345678901234567890_u256.try_into().unwrap();
    let proxy = deploy_l1_staking_proxy(l1_owner, staker, token);
    
    let proxy_address = proxy.contract_address;
    let amount = 1000_u128;
    let delegate = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    
    // Setup: Transfer tokens and stake first
    start_cheat_caller_address(token.contract_address, contract_address_const::<0>());
    token.transfer(proxy_address, amount.into());
    stop_cheat_caller_address(token.contract_address);
    
    start_cheat_caller_address(token.contract_address, proxy_address);
    token.approve(staker.contract_address, amount.into());
    stop_cheat_caller_address(token.contract_address);
    
    // Stake first
    let stake_params = StakeParams { delegate, amount };
    let stake_operation = StakingOperation::Stake(stake_params);
    let mut stake_payload = array![];
    Serde::serialize(@stake_operation, ref stake_payload);
    proxy.handle_l1_message(l1_owner.into(), stake_payload.span());
    
    // Now withdraw
    let withdraw_params = WithdrawParams { delegate, recipient, amount };
    let withdraw_operation = StakingOperation::Withdraw(withdraw_params);
    let mut withdraw_payload = array![];
    Serde::serialize(@withdraw_operation, ref withdraw_payload);
    
    let mut spy = spy_events();
    proxy.handle_l1_message(l1_owner.into(), withdraw_payload.span());
    
    // Check that withdrawal happened
    assert(staker.get_staked(proxy_address, delegate) == 0, 'Withdrawal failed');
    assert(staker.get_delegated(delegate) == 0, 'Undelegation failed');
    assert(token.balanceOf(recipient) == amount.into(), 'Recipient balance wrong');
    
    // Check events
    spy.assert_emitted(@array![
        (proxy_address, L1StakingProxy::Event::Withdrawn(
            L1StakingProxy::Withdrawn { delegate, recipient, amount }
        ))
    ]);
}

#[test]
#[should_panic(expected: 'UNAUTHORIZED_L1_CALLER')]
fn test_unauthorized_l1_message() {
    let token = deploy_test_token();
    let staker = deploy_staker(token);
    let l1_owner: EthAddress = 0x1234567890123456789012345678901234567890_u256.try_into().unwrap();
    let proxy = deploy_l1_staking_proxy(l1_owner, staker, token);
    
    // Try to send message from wrong L1 address
    let wrong_l1_address: felt252 = 0x9999999999999999999999999999999999999999;
    let delegate = contract_address_const::<0x123>();
    let amount = 1000_u128;
    
    let stake_params = StakeParams { delegate, amount };
    let operation = StakingOperation::Stake(stake_params);
    let mut payload = array![];
    Serde::serialize(@operation, ref payload);
    
    proxy.handle_l1_message(wrong_l1_address, payload.span());
}

#[test]
fn test_emergency_transfer() {
    let token = deploy_test_token();
    let staker = deploy_staker(token);
    let l1_owner: EthAddress = 0x1234567890123456789012345678901234567890_u256.try_into().unwrap();
    let proxy = deploy_l1_staking_proxy(l1_owner, staker, token);
    
    let proxy_address = proxy.contract_address;
    let amount = 1000_u256;
    let recipient = contract_address_const::<0x456>();
    
    // Transfer tokens to proxy
    start_cheat_caller_address(token.contract_address, contract_address_const::<0>());
    token.transfer(proxy_address, amount);
    stop_cheat_caller_address(token.contract_address);
    
    // Create emergency transfer operation
    let emergency_params = governance::l1_staking_proxy::EmergencyTransferParams {
        token: token.contract_address,
        recipient,
        amount,
    };
    let operation = StakingOperation::EmergencyTransfer(emergency_params);
    let mut payload = array![];
    Serde::serialize(@operation, ref payload);
    
    let mut spy = spy_events();
    proxy.handle_l1_message(l1_owner.into(), payload.span());
    
    // Check that transfer happened
    assert(token.balanceOf(recipient) == amount, 'Emergency transfer failed');
    assert(token.balanceOf(proxy_address) == 0, 'Proxy balance not zero');
    
    // Check events
    spy.assert_emitted(@array![
        (proxy_address, L1StakingProxy::Event::EmergencyTransferExecuted(
            L1StakingProxy::EmergencyTransferExecuted {
                token: token.contract_address,
                recipient,
                amount,
            }
        ))
    ]);
}
