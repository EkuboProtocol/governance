// EKU-1232 T2 Starknet hop, LOCAL snforge only (not Starknet Sepolia): a short-period Governor with
// the T2 testnet config executes a proposal whose single call is `send_message_to_l1(proxy,
// felts)`, and the emitted L2->L1 message is exactly the vector produced by
// `l1_proxy/test/T2Config.t.sol::test_l1MessageVector` (BNB testnet owner() proof, proxy nonce 0,
// fixture deployer). The Ethereum side consumes these felts in T2RehearsalFork.
use governance::governor::{Config, IGovernorDispatcher, IGovernorDispatcherTrait};
use governance::interfaces::erc20::IERC20DispatcherTrait;
use governance::staker::IStakerDispatcherTrait;
use governance::staker_test::setup as setup_staker;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, MessageToL1SpyTrait, declare, spy_messages_to_l1,
    start_cheat_block_timestamp_global as set_block_timestamp, start_cheat_caller_address_global,
    stop_cheat_caller_address_global,
};
use starknet::account::Call;
use starknet::{ContractAddress, EthAddress, get_block_timestamp, get_contract_address};

fn t2_config() -> Config {
    Config {
        voting_start_delay: 60,
        voting_period: 600,
        voting_weight_smoothing_duration: 60,
        quorum: 1_000_000_000_000_000_000,
        proposal_creation_threshold: 1_000_000_000_000_000_000,
        execution_delay: 60,
        execution_window: 604800,
    }
}

fn vector_proxy() -> EthAddress {
    0x0e0BEfdC32bb258d2D9b0421024069bEbd4524c0_felt252.try_into().unwrap()
}

fn vector_felts() -> Array<felt252> {
    array![
        0x9f48ec57c72ae34b87d57cc35273a725f7353b84, 0x0, 0x0, 0x1e4,
        0x17c20701000000000000000000000000000000000000000000000000b81591,
        0x70038f96fb0000000000000000000000000000000000000000000000000000,
        0x493e000000000000000000000000000000000000000000000000000,
        0x6acfc000000000000000000000000000000000000000000000000000,
        0x800000000000000000000000000000000000000000000000,
        0x200000000000000000000000000000000000000000000,
        0x40000000000000000000000000000000000000000000,
        0xc00000000000000000000000000e0befdc32bb258d,
        0x2d9b0421024069bebd4524c000000000000000000000000000000000000000,
        0x40000000000000000000000000000000000000, 0x48da5cb5b00000000000000000000000000, 0x9f48ec57,
        0xc72ae34b87d57cc35273a725f7353b84000000000000000000000000000000,
        0x400000000000000000000000000000, 0x48da5cb5b000000000000000000, 0x0,
    ]
}

fn proposer() -> ContractAddress {
    't2_proposer'.try_into().unwrap()
}

fn as_caller(address: ContractAddress) {
    stop_cheat_caller_address_global();
    if address != get_contract_address() {
        start_cheat_caller_address_global(address);
    }
}

fn advance(by: u64) {
    set_block_timestamp(get_block_timestamp() + by);
}

#[test]
fn test_t2_send_message_to_l1_selector() {
    assert(
        selector!(
            "send_message_to_l1",
        ) == 0x028148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007,
        'selector',
    );
}

#[test]
fn test_t2_governor_emits_exact_l1_message() {
    set_block_timestamp(1_791_000_000);
    let config = t2_config();
    let (staker, token) = setup_staker(10_000_000_000_000_000_000);
    let mut args: Array<felt252> = array![];
    Serde::serialize(@(staker, config), ref args);
    let (address, _) = declare("Governor").unwrap().contract_class().deploy(@args).unwrap();
    let governor = IGovernorDispatcher { contract_address: address };

    token.approve(staker.contract_address, 2_000_000_000_000_000_000);
    staker.stake(proposer());
    advance(config.voting_weight_smoothing_duration);

    let mut calldata: Array<felt252> = array![vector_proxy().into(), 20];
    for f in vector_felts() {
        calldata.append(f);
    }
    let call = Call {
        to: governor.contract_address,
        selector: selector!("send_message_to_l1"),
        calldata: calldata.span(),
    };

    as_caller(proposer());
    let id = governor.propose(array![call].span());
    advance(config.voting_start_delay);
    governor.vote(id, true);
    advance(config.voting_period + config.execution_delay);

    as_caller(get_contract_address());
    let mut spy = spy_messages_to_l1();
    governor.execute(id, array![call].span());

    let messages = spy.get_messages().messages;
    assert(messages.len() == 1, 'one L2->L1 message');
    let (from, message) = messages.at(0);
    assert(*from == governor.contract_address, 'from Governor');
    assert(*message.to_address == vector_proxy(), 'to proxy');
    assert(message.payload.span() == vector_felts().span(), 'exact felts');
}
