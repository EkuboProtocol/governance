use core::array::SpanTrait;
use array::{ArrayTrait};
use debug::PrintTrait;
use governance::governor::{
    IGovernorDispatcher, IGovernorDispatcherTrait, Governor, Config, ProposalInfo
};
use governance::token::{ITokenDispatcher, ITokenDispatcherTrait};
use governance::call_trait::{CallTrait};
use starknet::account::{Call};
use governance::tests::timelock_test::{single_call, transfer_call, deploy as deploy_timelock};
use governance::tests::utils;
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
    get_block_timestamp, testing::{set_block_timestamp, set_contract_address}
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};
use governance::tests::token_test::{deploy as deploy_token};
use serde::Serde;


fn deploy(config: Config) -> IGovernorDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@config, ref constructor_args);

    let (address, _) = deploy_syscall(
        Governor::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IGovernorDispatcher { contract_address: address };
}

fn create_proposal(governance: IGovernorDispatcher, token: ITokenDispatcher) -> felt252 {
    let recipient = utils::recipient();
    let proposer = utils::proposer();
    let start_time = utils::timestamp();
    let transfer_call = transfer_call(token: token, recipient: recipient, amount: 100);

    // Delegate token to the proposer so that he reaches threshold.
    token.delegate(proposer);

    set_block_timestamp(start_time);
    set_contract_address(proposer);
    let id = governance.propose(transfer_call);
    set_contract_address(utils::zero_address());
    id
}

/////////////////////////////
// DEPLOYMENT TESTS
/////////////////////////////

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

/////////////////////////////
// PROPOSAL CREATION TESTS
/////////////////////////////
#[test]
#[available_gas(3000000)]
fn test_propose() {
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
    let id = create_proposal(governance, token);

    let proposal = governance.get_proposal(id);
    let proposer = utils::proposer();
    let start_time = utils::timestamp();
    assert(
        proposal == ProposalInfo {
            proposer, creation_timestamp: start_time, yes: 0, no: 0, executed: false
        },
        'proposal doesnt match'
    );
}


#[test]
#[available_gas(4000000)]
#[should_panic(expected: ('ALREADY_PROPOSED', 'ENTRYPOINT_FAILED'))]
fn test_propose_already_exists_should_fail() {
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
    create_proposal(governance, token);
    // Trying to propose again with the same call should fail.
    create_proposal(governance, token);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('THRESHOLD', 'ENTRYPOINT_FAILED'))]
fn test_propose_below_threshold_should_fail() {
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

    let recipient = utils::recipient();
    let proposer = utils::proposer();
    let start_time = utils::timestamp();
    let transfer_call = transfer_call(token: token, recipient: recipient, amount: 100);

    // Don't delegate tokens to the proposer so that he doesn't reach threshold.

    set_block_timestamp(start_time);
    set_contract_address(proposer);
    governance.propose(transfer_call);
}

////////////////////////////////
// VOTING TESTS
////////////////////////////////

#[test]
#[available_gas(5000000)]
fn test_vote_yes() {
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
    let id = create_proposal(governance, token);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.delegate(voter);

    set_contract_address(voter);
    governance.vote(id, true); // vote yes

    let proposal = governance.get_proposal(id);
    assert(
        proposal.yes == token.get_average_delegated_over_last(voter, 30),
        'Yes vote count does not match'
    );

    assert(proposal.no == 0, 'No vote count does not match');
}

#[test]
#[available_gas(5000000)]
fn test_vote_no() {
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
    let id = create_proposal(governance, token);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.delegate(voter);

    set_contract_address(voter);
    governance.vote(id, false); // vote no

    let proposal = governance.get_proposal(id);
    assert(
        proposal.no == token.get_average_delegated_over_last(voter, 30),
        'No vote count does not match'
    );

    assert(proposal.yes == 0, 'Yes vote count should be 0');
}

#[test]
#[available_gas(4000000)]
#[should_panic(expected: ('VOTING_NOT_STARTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_before_voting_start_should_fail() {
    // Initial setup similar to propose test
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
    let id = create_proposal(governance, token);
    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Delegate token to the voter to give him voting power.
    token.delegate(voter);

    // Do not fast forward to voting period this time
    set_contract_address(voter);
    governance.vote(id, true); // vote yes
}

#[test]
#[available_gas(5000000)]
#[should_panic(expected: ('ALREADY_VOTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_already_voted_should_fail() {
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
    let id = create_proposal(governance, token);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.delegate(voter);

    set_contract_address(voter);
    governance.vote(id, true); // vote yes

    // Trying to vote again should fail
    governance.vote(id, true); // vote yes
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_vote_after_voting_period_should_fail() {
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
    let id = create_proposal(governance, token);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to after the voting period
    set_block_timestamp(start_time + 3600 + 60);
    set_contract_address(voter);

    governance.vote(id, true); // vote should fail
}

////////////////////////////////
// CANCELLATION TESTS
////////////////////////////////

#[test]
#[available_gas(3000000)]
fn test_cancel_by_proposer() {
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
    let proposer = utils::proposer();
    let start_time = utils::timestamp();

    let id = create_proposal(governance, token);

    set_contract_address(proposer);
    governance.cancel(id); // Cancel the proposal

    // Expect that proposal is no longer available
    let proposal = governance.get_proposal(id);
    assert(
        proposal == ProposalInfo {
            proposer: contract_address_const::<0>(),
            creation_timestamp: 0,
            yes: 0,
            no: 0,
            executed: false
        },
        'proposal not cancelled'
    );
}

#[test]
#[available_gas(6000000)]
fn test_cancel_by_non_proposer() {
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
    let user = utils::user();
    let proposer = utils::proposer();
    let mut current_timestamp = utils::timestamp();

    let id = create_proposal(governance, token);

    // Delegate token to user so that proposer looses his threshold.
    set_contract_address(utils::zero_address());
    token.delegate(utils::zero_address());

    // Fast forward one smoothing duration
    current_timestamp += 30;
    set_block_timestamp(current_timestamp);

    // A random user can now cancel the proposal
    set_contract_address(user);
    governance.cancel(id);

    // Expect that proposal is no longer available
    let proposal = governance.get_proposal(id);
    assert(
        proposal == ProposalInfo {
            proposer: contract_address_const::<0>(),
            creation_timestamp: 0,
            yes: 0,
            no: 0,
            executed: false
        },
        'proposal not cancelled'
    );
}

#[test]
#[available_gas(4000000)]
#[should_panic(expected: ('THRESHOLD_NOT_BREACHED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_by_non_proposer_threshold_not_breached_should_fail() {
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
    let user = utils::user();
    let proposer = utils::proposer();
    let mut current_timestamp = utils::timestamp();

    let id = create_proposal(governance, token);

    // A random user can't now cancel the proposal because
    // the proposer's voting power is still above threshold
    set_contract_address(user);
    governance.cancel(id);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_after_voting_end_should_fail() {
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
    let proposer = utils::proposer();
    let start_time = utils::timestamp();

    let id = create_proposal(governance, token);

    // Fast forward to after the voting ended
    set_block_timestamp(start_time + 3661);
    set_contract_address(proposer);

    governance.cancel(id); // Try to cancel the proposal after voting started
}

////////////////////////////////
// EXECUTION TESTS
////////////////////////////////

#[test]
#[available_gas(6000000)]
fn test_execute_valid_proposal() {
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
    let id = create_proposal(governance, token);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts
    set_contract_address(utils::proposer());
    governance.vote(id, true); // vote so that proposal reaches quorum
    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. Caller address should be 0.
    set_contract_address(utils::zero_address());

    // Send 100 tokens to the gov contract - this is because
    // the proposal calls transfer() which requires gov to have tokens.
    token.transfer(governance.contract_address, 100);
    // set_caller_address(utils::zero_address());

    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);

    let proposal = governance.get_proposal(id);
    assert(proposal.executed, 'execute failed');
    assert(token.balance_of(utils::recipient()) == 100, 'balance after execute');
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('VOTING_NOT_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_execute_before_voting_ends_should_fail() {
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
    let id = create_proposal(governance, token);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts

    // Execute the proposal. The vote is still active, this should fail.
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
}


#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_execute_quorum_not_met_should_fail() {
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
    let id = create_proposal(governance, token);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3661;
    set_block_timestamp(current_timestamp); // voting period ends
    set_contract_address(utils::proposer());

    // Execute the proposal. The quorum was not met, this should fail.
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
}

#[test]
#[available_gas(100000000)]
#[should_panic(expected: ('NO_MAJORITY', 'ENTRYPOINT_FAILED'))]
fn test_execute_no_majority_should_fail() {
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
    let id = create_proposal(governance, token);
    let voter = utils::voter();
    let voter2 = utils::voter2();
    let mut current_timestamp = utils::timestamp();
    token.transfer(voter, 49);
    token.transfer(voter2, 51);
    set_contract_address(voter);
    token.delegate(voter);
    set_contract_address(voter2);
    token.delegate(voter2);

    // self-delegate tokens to get voting power

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts

    // vote exactly at the quorum but 'no' votes are the majority
    set_contract_address(voter);
    governance.vote(id, true);
    set_contract_address(voter2);
    governance.vote(id, false);

    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. The quorum was not met, this should fail.
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
}

#[test]
#[available_gas(100000000)]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_execute_already_executed_should_fail() {
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
    let id = create_proposal(governance, token);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts
    set_contract_address(utils::proposer());
    governance.vote(id, true); // vote so that proposal reaches quorum
    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. Caller address should be 0.
    set_contract_address(utils::zero_address());

    // Send 100 tokens to the gov contract - this is because
    // the proposal calls transfer() which requires gov to have tokens.
    token.transfer(governance.contract_address, 100);
    // set_caller_address(utils::zero_address());

    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call); // Try to execute again
}

////////////////////////////////
// END TO END TESTS
////////////////////////////////

fn queue_with_timelock_call(timelock: ITimelockDispatcher, calls: Span<Call>) -> Call {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@calls, ref calldata);
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
    let start_time = utils::timestamp();
    set_block_timestamp(start_time);

    let delegate = utils::delegate();
    token.delegate(delegate);

    // so the average delegation is sufficient
    set_block_timestamp(start_time + 5);

    token.transfer(timelock.contract_address, 200);
    let recipient = utils::recipient();
    let timelock_calls = single_call(
        call: transfer_call(token: token, recipient: recipient, amount: 100)
    );

    set_contract_address(delegate);
    let id = governance.propose(queue_with_timelock_call(timelock, timelock_calls));
    set_block_timestamp(start_time + 5 + 3600);
    governance.vote(id, true);
    set_block_timestamp(start_time + 5 + 3600 + 60);
    let mut result = governance.execute(queue_with_timelock_call(timelock, timelock_calls));
    assert(result.len() == 1, '1 result');
    let queued_call_id = result.pop_front();
    set_block_timestamp(start_time + 5 + 3600 + 60 + 60);
    assert(token.balance_of(timelock.contract_address) == 200, 'balance before t');
    assert(token.balance_of(recipient) == 0, 'balance before r');
    timelock.execute(timelock_calls);
    assert(token.balance_of(timelock.contract_address) == 100, 'balance after t');
    assert(token.balance_of(recipient) == 100, 'balance before r');
}
