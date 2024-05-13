use core::array::SpanTrait;
use core::array::{ArrayTrait};
use core::num::traits::zero::{Zero};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::serde::Serde;
use core::traits::{TryInto};

use governance::execution_state::{ExecutionState};
use governance::governor::{
    IGovernorDispatcher, IGovernorDispatcherTrait, Governor, Config, ProposalInfo,
    Governor::{hash_calls}
};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
use governance::staker_test::{setup as setup_staker};
use starknet::account::{Call};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress, get_block_timestamp,
    testing::{set_block_timestamp, set_contract_address, pop_log}
};


pub(crate) fn recipient() -> ContractAddress {
    'recipient'.try_into().unwrap()
}

pub(crate) fn proposer() -> ContractAddress {
    'proposer'.try_into().unwrap()
}

pub(crate) fn delegate() -> ContractAddress {
    'delegate'.try_into().unwrap()
}

pub(crate) fn voter1() -> ContractAddress {
    'voter1'.try_into().unwrap()
}

pub(crate) fn voter2() -> ContractAddress {
    'voter2'.try_into().unwrap()
}

pub(crate) fn anyone() -> ContractAddress {
    'anyone'.try_into().unwrap()
}

fn advance_time(by: u64) -> u64 {
    let next = get_block_timestamp() + by;
    set_block_timestamp(next);
    next
}

fn transfer_call(token: IERC20Dispatcher, recipient: ContractAddress, amount: u256) -> Call {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(recipient, amount), ref calldata);

    Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata.span()
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

fn setup() -> (IStakerDispatcher, IERC20Dispatcher, IGovernorDispatcher, Config) {
    let (staker, token) = setup_staker(1000000);
    let config = Config {
        voting_start_delay: 86400,
        voting_period: 604800,
        voting_weight_smoothing_duration: 43200,
        quorum: 500,
        proposal_creation_threshold: 50,
        execution_delay: 86400,
        execution_window: 604800,
    };
    let governor = deploy(staker, config);

    (staker, token, governor, config)
}

// goes through the flow to create a proposal based on the governor
fn create_proposal(
    governor: IGovernorDispatcher, token: IERC20Dispatcher, staker: IStakerDispatcher
) -> felt252 {
    create_proposal_with_call(
        governor, token, staker, transfer_call(token, recipient(), amount: 100)
    )
}

fn create_proposal_with_call(
    governor: IGovernorDispatcher, token: IERC20Dispatcher, staker: IStakerDispatcher, call: Call
) -> felt252 {
    // Delegate token to the proposer so that he reaches threshold.
    token
        .approve(staker.contract_address, governor.get_config().proposal_creation_threshold.into());
    staker.stake(proposer());

    advance_time(governor.get_config().voting_weight_smoothing_duration);

    let address_before = get_contract_address();
    set_contract_address(proposer());
    let id = governor.propose(array![call].span());
    set_contract_address(address_before);
    id
}

#[test]
fn test_hash_call() {
    assert_eq!(
        hash_calls(
            @array![
                Call {
                    to: contract_address_const::<'to'>(),
                    selector: 'selector',
                    calldata: array![1, 2, 3].span()
                }
            ]
                .span()
        ),
        207204210864586401596949218336835721921077270974490243136789894626374071116
    );
}

#[test]
fn test_setup() {
    let (staker, token, governor, config) = setup();

    assert_eq!(governor.get_staker().get_token(), token.contract_address);
    assert_eq!(governor.get_staker().contract_address, staker.contract_address);
    assert_eq!(governor.get_config(), config);
}


#[test]
fn test_propose() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(proposer());
    let id = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());

    let proposal = governor.get_proposal(id);

    assert_eq!(
        proposal,
        ProposalInfo {
            calls_hash: hash_calls(@array![transfer_call(token, recipient(), amount: 100)].span()),
            proposer: proposer(),
            execution_state: ExecutionState {
                created: config.voting_weight_smoothing_duration, executed: 0, canceled: 0
            },
            yea: 0,
            nay: 0,
            config_version: 0,
        }
    );
}

#[test]
#[should_panic(expected: ('PROPOSER_HAS_ACTIVE_PROPOSAL', 'ENTRYPOINT_FAILED'))]
fn test_propose_has_active_proposal() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(proposer());
    governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    governor.propose(array![transfer_call(token, recipient(), amount: 101)].span());
}

#[test]
fn test_proposer_can_cancel_and_re_propose() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(proposer());
    let id_1 = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    governor.cancel(id_1);
    let id_2 = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    assert_ne!(id_1, id_2);
}

#[test]
fn test_proposer_can_wait_out_original_proposal_and_re_propose() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(proposer());
    let id_1 = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    advance_time(config.voting_period + config.voting_start_delay);
    let id_2 = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    assert_ne!(id_1, id_2);
}

#[test]
fn test_proposer_can_cancel_and_propose_different() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(proposer());
    let id = governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
    governor.cancel(id);
    governor.propose(array![transfer_call(token, recipient(), amount: 101)].span());
}

#[test]
fn test_propose_already_exists_should_suceed() {
    let (staker, token, governor, config) = setup();

    let id_1 = create_proposal(governor, token, staker);
    advance_time(config.voting_start_delay + config.voting_period);
    let id_2 = create_proposal(governor, token, staker);
    assert_ne!(id_1, id_2);
}

#[test]
#[should_panic(expected: ('THRESHOLD', 'ENTRYPOINT_FAILED'))]
fn test_propose_below_threshold_should_fail() {
    let (_staker, token, governor, config) = setup();

    set_contract_address(proposer());
    // since time starts at 0, we have to advance time by the duration just so the staker doesn't revert on time - voting_weight_smoothing_duration
    advance_time(config.voting_weight_smoothing_duration);
    // no tokens delegated to the proposer
    governor.propose(array![transfer_call(token, recipient(), amount: 100)].span());
}

#[test]
fn test_vote_yes() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay);

    token.approve(staker.contract_address, 900);
    staker.stake(voter1());

    set_contract_address(voter1());
    governor.vote(id, true); // vote yes

    let proposal = governor.get_proposal(id);
    assert_eq!(
        proposal.yea,
        staker.get_average_delegated_over_last(voter1(), config.voting_weight_smoothing_duration)
    );
    assert_eq!(proposal.nay, 0);
}

#[test]
fn test_anyone_can_vote() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay);

    set_contract_address(anyone());
    governor.vote(id, true);

    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.yea, 0);
    assert_eq!(proposal.nay, 0);
}

#[test]
fn test_describe_proposal_successful() {
    let (staker, token, governor, _config) = setup();
    let id = create_proposal(governor, token, staker);

    set_contract_address(proposer());
    governor
        .describe(
            id,
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
        );
    pop_log::<Governor::Proposed>(governor.contract_address).unwrap();
    assert_eq!(
        pop_log::<Governor::Described>(governor.contract_address).unwrap(),
        Governor::Described {
            id,
            description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
        }
    );
}


#[test]
fn test_propose_and_describe_successful() {
    let (staker, token, governor, config) = setup();
    token.approve(staker.contract_address, config.proposal_creation_threshold.into());
    staker.stake(proposer());

    advance_time(config.voting_weight_smoothing_duration);

    let address_before = get_contract_address();
    set_contract_address(proposer());
    let id = governor
        .propose_and_describe(
            array![].span(),
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
        );
    set_contract_address(address_before);

    pop_log::<Governor::Proposed>(governor.contract_address).unwrap();
    assert_eq!(
        pop_log::<Governor::Described>(governor.contract_address).unwrap(),
        Governor::Described {
            id,
            description: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
        }
    );
}

#[test]
#[should_panic(expected: ('NOT_PROPOSER', 'ENTRYPOINT_FAILED'))]
fn test_describe_proposal_fails_for_unknown_proposal() {
    let (staker, token, governor, _config) = setup();
    let id = create_proposal(governor, token, staker);
    governor.describe(id, "I am not the proposer");
}

#[test]
#[should_panic(expected: ('PROPOSAL_CANCELED', 'ENTRYPOINT_FAILED'))]
fn test_describe_proposal_fails_if_canceled() {
    let (staker, token, governor, _config) = setup();
    let id = create_proposal(governor, token, staker);
    set_contract_address(proposer());
    governor.cancel(id);
    governor.describe(id, "This proposal is canceled");
}

#[test]
#[should_panic(expected: ('DOES_NOT_EXIST', 'ENTRYPOINT_FAILED'))]
fn test_describe_proposal_fails_if_not_proposer() {
    let (_staker, _token, governor, _config) = setup();
    governor.describe(123, "This proposal does not exist");
}

#[test]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_describe_proposal_fails_if_executed() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal_with_call(
        governor, token, staker, transfer_call(token: token, recipient: anyone(), amount: 0)
    );

    // make the proposal execute
    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());
    advance_time(config.voting_start_delay);
    set_contract_address(proposer());
    governor.vote(id, true);
    set_contract_address(voter1());
    governor.vote(id, true);
    advance_time(config.voting_period + config.execution_delay);
    set_contract_address(anyone());
    governor.execute(id, array![transfer_call(token, anyone(), amount: 0)].span());

    set_contract_address(proposer());
    governor.describe(id, "This proposal is already executed");
}

#[test]
fn test_vote_no_staking_after_period_starts() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay);

    // Delegate token to the voter to give him voting power.
    token.approve(staker.contract_address, 900);
    staker.stake(voter1());

    set_contract_address(voter1());
    governor.vote(id, false); // vote no

    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.nay, 0);
    assert_eq!(proposal.yea, 0);
}


#[test]
#[should_panic(expected: ('DOES_NOT_EXIST', 'ENTRYPOINT_FAILED'))]
fn test_vote_invalid_proposal() {
    let (_, _, governor, _) = setup();

    governor.vote(123, true);
}

#[test]
#[should_panic(expected: ('PROPOSAL_CANCELED', 'ENTRYPOINT_FAILED'))]
fn test_vote_after_cancel_proposal() {
    let (staker, token, governor, _config) = setup();

    let id = create_proposal(governor, token, staker);
    set_contract_address(proposer());
    governor.cancel(id);
    set_contract_address(voter1());
    governor.vote(id, true);
}

#[test]
#[should_panic(expected: ('VOTING_NOT_STARTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_before_voting_start_should_fail() {
    let (staker, token, governor, config) = setup();

    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay - 1);

    set_contract_address(voter1());
    governor.vote(id, true);
}

#[test]
#[should_panic(expected: ('ALREADY_VOTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_already_voted_should_fail() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay);

    set_contract_address(voter1());
    governor.vote(id, true);

    // Trying to vote twice on the same proposal should fail
    governor.vote(id, true);
}

#[test]
#[should_panic(expected: ('ALREADY_VOTED', 'ENTRYPOINT_FAILED'))]
fn test_vote_already_voted_different_vote_should_fail() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    // Fast forward to voting period
    advance_time(config.voting_start_delay);

    set_contract_address(voter1());
    governor.vote(id, true);

    // Different vote should still fail
    governor.vote(id, false);
}

#[test]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_vote_after_voting_period_should_fail() {
    let (staker, token, governor, config) = setup();

    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_period + config.voting_start_delay);
    set_contract_address(voter1());

    governor.vote(id, true); // vote should fail
}

#[test]
#[should_panic(expected: ('DOES_NOT_EXIST', 'ENTRYPOINT_FAILED'))]
fn test_cancel_fails_if_proposal_not_exists() {
    let (_staker, _token, governor, _config) = setup();
    let id = 1234;
    governor.cancel(id);
}

#[test]
fn test_cancel_by_proposer() {
    let (staker, token, governor, config) = setup();

    let proposer = proposer();

    let id = create_proposal(governor, token, staker);

    advance_time(30);

    set_contract_address(proposer);
    governor.cancel(id);

    let proposal = governor.get_proposal(id);
    assert_eq!(
        proposal,
        ProposalInfo {
            calls_hash: hash_calls(@array![transfer_call(token, recipient(), amount: 100)].span()),
            proposer: proposer(),
            execution_state: ExecutionState {
                created: config.voting_weight_smoothing_duration,
                executed: 0,
                canceled: config.voting_weight_smoothing_duration + 30
            },
            yea: 0,
            nay: 0,
            config_version: 0,
        }
    );
}

#[test]
#[should_panic(expected: ('ALREADY_CANCELED', 'ENTRYPOINT_FAILED'))]
fn test_double_cancel_by_proposer() {
    let (staker, token, governor, _config) = setup();

    let proposer = proposer();

    let id = create_proposal(governor, token, staker);

    advance_time(30);

    set_contract_address(proposer);
    governor.cancel(id);
    governor.cancel(id);
}

#[test]
fn test_cancel_by_non_proposer() {
    let (staker, token, governor, config) = setup();

    let id = create_proposal(governor, token, staker);
    staker.withdraw_amount(proposer(), recipient: Zero::zero(), amount: 25);

    // Fast forward one smoothing duration
    advance_time(config.voting_weight_smoothing_duration);

    // A random user can now cancel the proposal
    set_contract_address(anyone());
    governor.cancel(id);

    // Expect that proposal is no longer available
    let proposal = governor.get_proposal(id);
    assert_eq!(
        proposal,
        ProposalInfo {
            calls_hash: hash_calls(
                @array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
            ),
            proposer: proposer(),
            execution_state: ExecutionState {
                created: config.voting_weight_smoothing_duration,
                executed: 0,
                canceled: config.voting_weight_smoothing_duration * 2
            },
            yea: 0,
            nay: 0,
            config_version: 0,
        }
    );
}

#[test]
#[should_panic(expected: ('THRESHOLD_NOT_BREACHED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_by_non_proposer_threshold_not_breached_should_fail() {
    let (staker, token, governor, _config) = setup();

    let id = create_proposal(governor, token, staker);

    // A random user can't now cancel the proposal because
    // the proposer's voting power is still above threshold
    set_contract_address(anyone());
    governor.cancel(id);
}

#[test]
#[should_panic(expected: ('VOTING_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_cancel_after_voting_end_should_fail() {
    let (staker, token, governor, config) = setup();
    let proposer = proposer();

    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay + config.voting_period);
    set_contract_address(proposer);

    governor.cancel(id); // Try to cancel the proposal after voting started
}

#[test]
fn test_execute_valid_proposal() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    // governor needs this token to execute proposal
    token.transfer(governor.contract_address, 100);

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());

    advance_time(config.voting_start_delay);
    set_contract_address(proposer());
    governor.vote(id, true);
    set_contract_address(voter1());
    governor.vote(id, true);

    advance_time(config.voting_period + config.execution_delay);

    set_contract_address(anyone());

    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );

    let proposal = governor.get_proposal(id);
    assert(proposal.execution_state.executed.is_non_zero(), 'execute failed');
    assert_eq!(token.balanceOf(recipient()), 100);
}

#[test]
#[should_panic(expected: ('PROPOSAL_CANCELED', 'ENTRYPOINT_FAILED'))]
fn test_canceled_proposal_cannot_be_executed() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    token.transfer(governor.contract_address, 100);

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());

    advance_time(config.voting_start_delay);
    set_contract_address(proposer());
    governor.vote(id, true);
    set_contract_address(voter1());
    governor.vote(id, true);

    set_contract_address(proposer());
    governor.cancel(id);

    advance_time(config.voting_period);

    set_contract_address(anyone());

    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
#[should_panic(expected: ('VOTING_NOT_ENDED', 'ENTRYPOINT_FAILED'))]
fn test_execute_before_voting_ends_should_fail() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay);

    // Execute the proposal. The vote is still active, this should fail.
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}


#[test]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_execute_quorum_not_met_should_fail() {
    let (staker, token, governor, config) = setup();
    let id = create_proposal(governor, token, staker);

    advance_time(config.voting_start_delay + config.voting_period + config.execution_delay);
    set_contract_address(proposer());

    // Execute the proposal. The quorum was not met, this should fail.
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
#[should_panic(expected: ('NO_MAJORITY', 'ENTRYPOINT_FAILED'))]
fn test_execute_no_majority_should_fail() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());
    token.approve(staker.contract_address, (config.quorum + 1).into());
    staker.stake(voter2());

    // now voter2 has enough weighted voting power to propose
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter2());
    let id = governor
        .propose(array![transfer_call(token: token, recipient: recipient(), amount: 100)].span());

    advance_time(config.voting_start_delay);

    // vote exactly at the quorum but 'no' votes are the majority
    set_contract_address(voter1());
    governor.vote(id, true);
    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.yea, config.quorum);
    assert_eq!(proposal.nay, 0);

    set_contract_address(voter2());
    governor.vote(id, false);
    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.yea, config.quorum);
    assert_eq!(proposal.nay, config.quorum + 1);

    advance_time(config.voting_period + config.execution_delay);

    // Execute the proposal. The majority of votes are no, this should fail.
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
#[should_panic(expected: ('EXECUTION_WINDOW_NOT_STARTED', 'ENTRYPOINT_FAILED'))]
fn test_execute_before_execution_window_begins() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());

    // now voter2 has enough weighted voting power to propose
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter1());
    let id = governor
        .propose(array![transfer_call(token: token, recipient: recipient(), amount: 100)].span());
    advance_time(config.voting_start_delay);
    governor.vote(id, true);

    advance_time(config.voting_period);
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}


#[test]
#[should_panic(expected: ('EXECUTION_WINDOW_OVER', 'ENTRYPOINT_FAILED'))]
fn test_execute_after_execution_window_ends() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(voter1());

    // now voter2 has enough weighted voting power to propose
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter1());
    let id = governor
        .propose(array![transfer_call(token: token, recipient: recipient(), amount: 100)].span());
    advance_time(config.voting_start_delay);
    governor.vote(id, true);

    advance_time(config.voting_period + config.execution_delay + config.execution_window);
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_verify_votes_are_counted_over_voting_weight_smoothing_duration_from_start() {
    let (staker, token, governor, config) = setup();

    // self-delegate tokens to get voting power
    let voter1 = voter1();
    let voter2 = voter2();

    token.transfer(voter1, 49);
    token.transfer(voter2, 51);
    set_contract_address(voter1);
    token.approve(staker.contract_address, 49);
    staker.stake(voter1);
    set_contract_address(voter2);
    token.approve(staker.contract_address, 51);
    staker.stake(voter2);

    // the full amount of delegation should be vested over 30 seconds
    advance_time(config.voting_weight_smoothing_duration);

    let id = governor
        .propose(array![transfer_call(token: token, recipient: recipient(), amount: 100)].span());

    advance_time(config.voting_start_delay - (config.voting_weight_smoothing_duration / 3));
    // undelegate 1/3rd of a duration before voting starts, so only a third of voting power is counted for voter1
    set_contract_address(voter1);
    staker.withdraw_amount(voter1, recipient: Zero::zero(), amount: 49);

    advance_time((config.voting_weight_smoothing_duration / 3));

    // vote less than quorum because of smoothing duration
    set_contract_address(voter1);
    governor.vote(id, true);
    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.yea, 32);
    assert_eq!(proposal.nay, 0);

    set_contract_address(voter2);
    governor.vote(id, false);
    let proposal = governor.get_proposal(id);
    assert_eq!(proposal.yea, 32);
    assert_eq!(proposal.nay, 51);

    advance_time(config.voting_period + config.execution_delay);

    // Execute the proposal. The quorum was not met, this should fail.
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
#[should_panic(expected: ('QUORUM_NOT_MET', 'ENTRYPOINT_FAILED'))]
fn test_quorum_counts_only_yes_votes_not_met() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake_amount(voter1(), (config.quorum - 1));
    staker.stake_amount(voter2(), 1);

    // the full amount of delegation should be vested over 30 seconds
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter1());
    let id = governor
        .propose(array![transfer_call(token: token, recipient: recipient(), amount: 100)].span());

    advance_time(config.voting_start_delay);
    governor.vote(id, true);

    set_contract_address(voter2());
    governor.vote(id, false);

    advance_time(config.voting_period + config.execution_delay);

    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
}

#[test]
fn test_quorum_counts_only_yes_votes_exactly_met() {
    let (staker, token, governor, config) = setup();
    let calls = array![
        transfer_call(token: token, recipient: recipient(), amount: 150),
        transfer_call(token: token, recipient: recipient(), amount: 50)
    ]
        .span();
    // so execution can succeed
    token.transfer(governor.contract_address, 200);

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake_amount(voter1(), (config.quorum - 1));
    staker.stake_amount(voter2(), 1);

    // the full amount of delegation should be vested over 30 seconds
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter1());
    let id = governor.propose(calls);

    advance_time(config.voting_start_delay);
    governor.vote(id, true);

    set_contract_address(voter2());
    governor.vote(id, true);

    advance_time(config.voting_period + config.execution_delay);

    governor.execute(id, calls);
}

#[test]
fn test_execute_emits_logs_from_data() {
    let (staker, token, governor, config) = setup();
    let calls = array![
        transfer_call(token: token, recipient: recipient(), amount: 150),
        transfer_call(token: token, recipient: recipient(), amount: 50)
    ]
        .span();
    // so execution can succeed
    token.transfer(governor.contract_address, 200);

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake_amount(voter1(), (config.quorum - 1));
    staker.stake_amount(voter2(), 1);

    // the full amount of delegation should be vested over 30 seconds
    advance_time(config.voting_weight_smoothing_duration);

    set_contract_address(voter1());
    let id = governor.propose(calls);

    advance_time(config.voting_start_delay);
    governor.vote(id, true);

    set_contract_address(voter2());
    governor.vote(id, true);

    advance_time(config.voting_period + config.execution_delay);

    let result = governor.execute(id, calls);
    let expected = array![array![1_felt252].span(), array![1].span()].span();
    // both transfers suceeded
    assert_eq!(result, expected);

    pop_log::<Governor::Proposed>(governor.contract_address).unwrap();
    pop_log::<Governor::Voted>(governor.contract_address).unwrap();
    pop_log::<Governor::Voted>(governor.contract_address).unwrap();
    // and the governor emitted it too
    let executed = pop_log::<Governor::Executed>(governor.contract_address).unwrap();
    assert_eq!(executed, Governor::Executed { id, result_data: expected });
}

#[test]
#[should_panic(expected: ('ALREADY_EXECUTED', 'ENTRYPOINT_FAILED'))]
fn test_execute_already_executed_should_fail() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(proposer());

    let id = create_proposal(governor, token, staker);
    token.transfer(governor.contract_address, 100);

    advance_time(config.voting_start_delay);
    set_contract_address(proposer());
    governor.vote(id, true); // vote so that proposal reaches quorum
    advance_time(config.voting_period + config.execution_delay);

    set_contract_address(anyone());
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        );
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 100)].span()
        ); // Try to execute again
}

#[test]
#[should_panic(expected: ('CALLS_HASH_MISMATCH', 'ENTRYPOINT_FAILED'))]
fn test_execute_invalid_call_id() {
    let (staker, token, governor, config) = setup();

    token.approve(staker.contract_address, config.quorum.into());
    staker.stake(proposer());

    let id = create_proposal(governor, token, staker);
    token.transfer(governor.contract_address, 100);

    advance_time(config.voting_start_delay);
    set_contract_address(proposer());
    governor.vote(id, true); // vote so that proposal reaches quorum
    advance_time(config.voting_period);

    set_contract_address(anyone());
    governor
        .execute(
            id, array![transfer_call(token: token, recipient: recipient(), amount: 101)].span()
        );
}
