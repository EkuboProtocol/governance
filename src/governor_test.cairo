use core::array::SpanTrait;
use array::{ArrayTrait};
use debug::PrintTrait;
use governance::governor::{IGovernorDispatcher, IGovernorDispatcherTrait, Governor, Config};
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait};
use governance::call_trait::{CallTrait};
use starknet::account::{Call};
use governance::timelock_test::{single_call, transfer_call, deploy as deploy_timelock};
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
    get_block_timestamp, testing::{set_block_timestamp, set_contract_address}
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};
use governance::token_test::{deploy as deploy_token};
use serde::Serde;


#[starknet::interface]
trait AccountContract<TContractState> {
    fn __validate_declare__(self: @TContractState, class_hash: felt252) -> felt252;
    fn __validate__(
        ref self: TContractState,
        contract_address: ContractAddress,
        entry_point_selector: felt252,
        calldata: Array<felt252>
    ) -> felt252;
    fn __execute__(ref self: TContractState, calls: Array<Call>) -> Span<felt252>;
}


fn deploy(config: Config) -> IGovernorDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@config, ref constructor_args);

    let (address, _) = deploy_syscall(
        Governor::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IGovernorDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_governance_deploy() {
    let token = deploy_token('Governor', 'GT', 1000);
    let governance = deploy(
        Config {
            voting_token: token,
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );

    let config = governance.get_config();
    assert(config.voting_token.contract_address == token.contract_address, 'token');
    assert(config.voting_start_delay == 3600, 'voting_start_delay');
    assert(config.voting_period == 60, 'voting_period');
    assert(config.voting_weight_smoothing_duration == 30, 'smoothing');
    assert(config.quorum == 100, 'quorum');
    assert(config.proposal_creation_threshold == 50, 'proposal_creation_threshold');
}

fn queue_with_timelock_call(timelock: ITimelockDispatcher, calls: @Array<Call>) -> Call {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(calls, ref calldata);
    Call {
        to: timelock.contract_address,
        // queue
        selector: 0x2c5ecd2faa027574e2101f9b6bdc19dec3f76beff12aa506ac3391be0022e46,
        calldata: calldata
    }
}

#[test]
#[available_gas(300000000)]
fn test_proposal_e2e() {
    let token = deploy_token('Governor', 'GT', 1000);
    let governance = deploy(
        Config {
            voting_token: token,
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let timelock = deploy_timelock(governance.contract_address, 60, 30);

    // must do this because timestamp 0 cannot get voting weights 30 seconds in the past
    let start_time = 1688122125;
    set_block_timestamp(start_time);

    let delegate = contract_address_const::<12345>();
    token.delegate(delegate);

    // so the average delegation is sufficient
    set_block_timestamp(start_time + 5);

    token.transfer(timelock.contract_address, 200);
    let recipient = contract_address_const::<12345>();
    let timelock_calls = single_call(
        call: transfer_call(token: token, recipient: recipient, amount: 100)
    );

    set_contract_address(delegate);
    let id = governance.propose(queue_with_timelock_call(timelock, @timelock_calls));
    set_block_timestamp(start_time + 5 + 3600);
    governance.vote(id, true);
    set_block_timestamp(start_time + 5 + 3600 + 60);
    let mut result = AccountContractDispatcher {
        contract_address: governance.contract_address
    }.__execute__(single_call(queue_with_timelock_call(timelock, @timelock_calls)));
    assert(result.len() == 1, '1 result');
    let queued_call_id = result.pop_front();
    set_block_timestamp(start_time + 5 + 3600 + 60 + 60);
    assert(token.balance_of(timelock.contract_address) == 200, 'balance before t');
    assert(token.balance_of(recipient) == 0, 'balance before r');
    timelock.execute(timelock_calls);
    assert(token.balance_of(timelock.contract_address) == 100, 'balance after t');
    assert(token.balance_of(recipient) == 100, 'balance before r');
}
