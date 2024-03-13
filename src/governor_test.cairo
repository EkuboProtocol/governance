use core::array::SpanTrait;
use core::array::{ArrayTrait};
use core::num::traits::zero::{Zero};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::serde::Serde;
use core::traits::{TryInto};

use governance::call_trait::{CallTrait};
use governance::governor::{
    IGovernorDispatcher, IGovernorDispatcherTrait, Governor, Config, ProposalInfo,
    ProposalTimestamps
};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
use governance::staker_test::{setup as setup_staker};
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
use governance::timelock_test::{single_call, transfer_call, deploy as deploy_timelock};
use starknet::account::{Call};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress, get_block_timestamp, testing::{set_block_timestamp, set_contract_address}
};

mod utils {
    use super::{ContractAddress};

    pub(crate) fn recipient() -> ContractAddress {
        'recipient'.try_into().unwrap()
    }

    pub(crate) fn proposer() -> ContractAddress {
        'proposer'.try_into().unwrap()
    }

    pub(crate) fn delegate() -> ContractAddress {
        'delegate'.try_into().unwrap()
    }

    pub(crate) fn voter() -> ContractAddress {
        'voter'.try_into().unwrap()
    }

    pub(crate) fn voter2() -> ContractAddress {
        'user2'.try_into().unwrap()
    }

    pub(crate) fn user() -> ContractAddress {
        'user'.try_into().unwrap()
    }


    pub(crate) fn timestamp() -> u64 {
        1688122125
    }
}

fn deploy(staker: IStakerDispatcher, config: Config) -> IGovernorDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(staker, config), ref constructor_args);

    let (address, _) = deploy_syscall(
        Governor::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_GV_FAILED');
    return IGovernorDispatcher { contract_address: address };
}

fn create_proposal(
    governance: IGovernorDispatcher, token: IERC20Dispatcher, staker: IStakerDispatcher
) -> felt252 {
    let recipient = utils::recipient();
    let proposer = utils::proposer();
    let start_time = utils::timestamp();
    let transfer_call = transfer_call(token, recipient, amount: 100);

    // Delegate token to the proposer so that he reaches threshold.
    token.approve(staker.contract_address, 100);
    staker.stake(proposer);

    set_block_timestamp(start_time);
    let address_before = get_contract_address();
    set_contract_address(proposer);
    let id = governance.propose(transfer_call);
    set_contract_address(address_before);
    id
}

/////////////////////////////
// DEPLOYMENT TESTS
/////////////////////////////

#[test]
fn test_governance_deploy() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let config = Config {
        voting_start_delay: 3600,
        voting_period: 60,
        voting_weight_smoothing_duration: 30,
        quorum: 100,
        proposal_creation_threshold: 50,
    };
    let governance = deploy(staker: staker, config: config);

    assert_eq!(governance.get_staker().get_token(), token.contract_address);
    assert_eq!(governance.get_staker().contract_address, staker.contract_address);
    assert_eq!(governance.get_config(), config);
}

/////////////////////////////
// PROPOSAL CREATION TESTS
/////////////////////////////
#[test]
fn test_propose() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);

    let proposal = governance.get_proposal(id);
    let proposer = utils::proposer();
    let start_time = utils::timestamp();
    assert(
        proposal == ProposalInfo {
            proposer,
            timestamps: ProposalTimestamps { created: start_time, executed: 0 },
            yea: 0,
            nay: 0
        },
        'proposal doesnt match'
    );
}


#[test]
#[should_panic(expected: ('ALREADY_PROPOSED', 'ENTRYPOINT_FAILED'))]
fn test_propose_already_exists_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    create_proposal(governance, token, staker);
    // Trying to propose again with the same call should fail.
    create_proposal(governance, token, staker);
}

#[test]
#[should_panic(expected: ('THRESHOLD', 'ENTRYPOINT_FAILED'))]
fn test_propose_below_threshold_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
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
fn test_vote_yes() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.approve(staker.contract_address, 900);
    staker.stake(voter);

    set_contract_address(voter);
    governance.vote(id, true); // vote yes

    let proposal = governance.get_proposal(id);
    assert_eq!(proposal.yea, staker.get_average_delegated_over_last(voter, 30));

    assert_eq!(proposal.nay, 0);
}

#[test]
fn test_vote_no_staking_after_period_starts() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.approve(staker.contract_address, 900);
    staker.stake(voter);

    set_contract_address(voter);
    governance.vote(id, false); // vote no

    let proposal = governance.get_proposal(id);
    assert_eq!(proposal.nay, 0);
    assert_eq!(proposal.yea, 0);
}

#[test]
#[should_panic(expected: ('VOTING_NOT_STARTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_before_voting_start_should_fail() {
    // Initial setup similar to propose test
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);
    let voter = utils::voter();

    // Delegate token to the voter to give him voting power.
    token.approve(staker.contract_address, 900);
    staker.stake(voter);

    // Do not fast forward to voting period this time
    set_contract_address(voter);
    governance.vote(id, true); // vote yes
}

#[test]
#[should_panic(expected: ('ALREADY_VOTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_already_voted_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);

    let start_time = utils::timestamp();
    let voter = utils::voter();

    // Fast forward to voting period
    set_block_timestamp(start_time + 3600);

    // Delegate token to the voter to give him voting power.
    token.approve(staker.contract_address, 900);
    staker.stake(voter);

    set_contract_address(voter);
    governance.vote(id, true); // vote yes

    // Trying to vote again should fail
    governance.vote(id, true); // vote yes
}

#[test]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_vote_after_voting_period_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);

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
fn test_cancel_by_proposer() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let proposer = utils::proposer();

    let id = create_proposal(governance, token, staker);

    set_contract_address(proposer);
    governance.cancel(id); // Cancel the proposal

    // Expect that proposal is no longer available
    let proposal = governance.get_proposal(id);
    assert(
        proposal == ProposalInfo {
            proposer: contract_address_const::<0>(),
            timestamps: ProposalTimestamps { created: 0, executed: 0 },
            yea: 0,
            nay: 0,
        },
        'proposal not cancelled'
    );
}

#[test]
fn test_cancel_by_non_proposer() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let user = utils::user();
    let mut current_timestamp = utils::timestamp();

    let id = create_proposal(governance, token, staker);

    staker.withdraw(utils::proposer(), recipient: Zero::zero(), amount: 100);
    // Fast forward one smoothing duration
    current_timestamp += 30;
    set_block_timestamp(current_timestamp);

    // A random user can now cancel the proposal
    set_contract_address(user);
    governance.cancel(id);

    // Expect that proposal is no longer available
    let proposal = governance.get_proposal(id);
    assert_eq!(
        proposal,
        ProposalInfo {
            proposer: contract_address_const::<0>(),
            timestamps: ProposalTimestamps { created: 0, executed: 0 },
            yea: 0,
            nay: 0,
        }
    );
}

#[test]
#[should_panic(expected: ('THRESHOLD_NOT_BREACHED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_by_non_proposer_threshold_not_breached_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let user = utils::user();

    let id = create_proposal(governance, token, staker);

    // A random user can't now cancel the proposal because
    // the proposer's voting power is still above threshold
    set_contract_address(user);
    governance.cancel(id);
}

#[test]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_after_voting_end_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let proposer = utils::proposer();
    let start_time = utils::timestamp();

    let id = create_proposal(governance, token, staker);

    // Fast forward to after the voting ended
    set_block_timestamp(start_time + 3661);
    set_contract_address(proposer);

    governance.cancel(id); // Try to cancel the proposal after voting started
}

////////////////////////////////
// EXECUTION TESTS
////////////////////////////////

#[test]
fn test_execute_valid_proposal() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts
    set_contract_address(utils::proposer());
    governance.vote(id, true); // vote so that proposal reaches quorum
    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. Caller address should be 0.
    set_contract_address(Zero::zero());

    // Send 100 tokens to the gov contract - this is because
    // the proposal calls transfer() which requires gov to have tokens.
    token.transfer(governance.contract_address, 100);
    // set_caller_address(Zero::zero());

    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);

    let proposal = governance.get_proposal(id);
    assert(proposal.timestamps.executed.is_non_zero(), 'execute failed');
    assert(token.balanceOf(utils::recipient()) == 100, 'balance after execute');
}

#[test]
#[should_panic(expected: ('VOTING_NOT_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_execute_before_voting_ends_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    create_proposal(governance, token, staker);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts

    // Execute the proposal. The vote is still active, this should fail.
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
}


#[test]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_execute_quorum_not_met_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    create_proposal(governance, token, staker);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3661;
    set_block_timestamp(current_timestamp); // voting period ends
    set_contract_address(utils::proposer());

    // Execute the proposal. The quorum was not met, this should fail.
    let transfer_call = transfer_call(token: token, recipient: utils::recipient(), amount: 100);
    governance.execute(transfer_call);
}

#[test]
#[should_panic(expected: ('NO_MAJORITY', 'ENTRYPOINT_FAILED'))]
fn test_execute_no_majority_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );

    let mut current_timestamp = utils::timestamp();
    set_block_timestamp(current_timestamp);

    // delegate tokens to 2 voters
    let voter1 = utils::voter();
    let voter2 = utils::voter2();

    token.transfer(voter1, 49);
    token.transfer(voter2, 51);
    set_contract_address(voter1);
    token.approve(staker.contract_address, 49);
    staker.stake(voter1);
    set_contract_address(voter2);
    token.approve(staker.contract_address, 51);
    staker.stake(voter2);

    // now voter2 has enough weighted voting power to propose
    current_timestamp += 30;
    set_block_timestamp(current_timestamp);

    let id = governance
        .propose(transfer_call(token: token, recipient: utils::recipient(), amount: 100));

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts

    // vote exactly at the quorum but 'no' votes are the majority
    set_contract_address(voter1);
    governance.vote(id, true);
    let proposal = governance.get_proposal(id);
    assert(proposal.yea == 49, 'yea after first');
    assert(proposal.nay.is_zero(), 'nay after first');

    set_contract_address(voter2);
    governance.vote(id, false);
    let proposal = governance.get_proposal(id);
    assert(proposal.yea == 49, 'yea after both');
    assert(proposal.nay == 51, 'nay after both');

    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. The majority of votes are no, this should fail.
    governance.execute(transfer_call(token: token, recipient: utils::recipient(), amount: 100));
}

#[test]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_verify_votes_are_counted_over_voting_weight_smoothing_duration_from_start() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );

    let mut current_timestamp = utils::timestamp();
    set_block_timestamp(current_timestamp);

    // self-delegate tokens to get voting power
    let voter1 = utils::voter();
    let voter2 = utils::voter2();

    token.transfer(voter1, 49);
    token.transfer(voter2, 51);
    set_contract_address(voter1);
    token.approve(staker.contract_address, 49);
    staker.stake(voter1);
    set_contract_address(voter2);
    token.approve(staker.contract_address, 51);
    staker.stake(voter2);

    // the full amount of delegation should be vested over 30 seconds
    current_timestamp += 30;
    set_block_timestamp(current_timestamp);

    let id = governance
        .propose(transfer_call(token: token, recipient: utils::recipient(), amount: 100));

    current_timestamp += 3580;
    set_block_timestamp(current_timestamp); // 20 seconds before voting starts
    // undelegate 20 seconds before voting starts, so only 1/3rd of voting power is counted for voter1
    set_contract_address(voter1);
    staker.withdraw(voter1, recipient: Zero::zero(), amount: 49);

    current_timestamp += 20;
    set_block_timestamp(current_timestamp); // voting starts

    // vote less than quorum because of smoothing duration
    set_contract_address(voter1);
    governance.vote(id, true);
    let proposal = governance.get_proposal(id);
    assert(proposal.yea == 16, 'yea after first');
    assert(proposal.nay.is_zero(), 'nay after first');

    set_contract_address(voter2);
    governance.vote(id, false);
    let proposal = governance.get_proposal(id);
    assert(proposal.yea == 16, 'yea after both');
    assert(proposal.nay == 51, 'nay after both');

    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. The quorum was not met, this should fail.
    governance.execute(transfer_call(token: token, recipient: utils::recipient(), amount: 100));
}

#[test]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_execute_already_executed_should_fail() {
    let (staker, token) = setup_staker(get_contract_address(), 1000);
    let governance = deploy(
        staker: staker,
        config: Config {
            voting_start_delay: 3600,
            voting_period: 60,
            voting_weight_smoothing_duration: 30,
            quorum: 100,
            proposal_creation_threshold: 50,
        }
    );
    let id = create_proposal(governance, token, staker);
    let mut current_timestamp = utils::timestamp();

    current_timestamp += 3601;
    set_block_timestamp(current_timestamp); // voting period starts
    set_contract_address(utils::proposer());
    governance.vote(id, true); // vote so that proposal reaches quorum
    current_timestamp += 60;
    set_block_timestamp(current_timestamp); // voting period ends

    // Execute the proposal. Caller address should be 0.
    set_contract_address(Zero::zero());

    // Send 100 tokens to the gov contract - this is because
    // the proposal calls transfer() which requires gov to have tokens.
    token.transfer(governance.contract_address, 100);
    // set_caller_address(Zero::zero());

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
        calldata: calldata.span()
    }
}

#[test]
fn test_proposal_e2e() {
    let (staker, token) = setup_staker(get_contract_address(), 1200);
    let governance = deploy(
        staker: staker,
        config: Config {
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
    token.approve(staker.contract_address, 1000);
    staker.stake(delegate);

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
    result.pop_front().unwrap();
    set_block_timestamp(start_time + 5 + 3600 + 60 + 60);
    assert(token.balanceOf(timelock.contract_address) == 200, 'balance before t');
    assert(token.balanceOf(recipient) == 0, 'balance before r');
    timelock.execute(timelock_calls);
    assert(token.balanceOf(timelock.contract_address) == 100, 'balance after t');
    assert(token.balanceOf(recipient) == 100, 'balance before r');
}
