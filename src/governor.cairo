use core::array::{Array};
use core::byte_array::{ByteArray};
use core::option::{Option, OptionTrait};
use core::traits::{Into, TryInto};
use governance::execution_state::{ExecutionState};
use governance::staker::{IStakerDispatcher};
use starknet::account::{Call};
use starknet::{ContractAddress, storage_access::{StorePacking}};

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct ProposalInfo {
    // the ID of the call that this proposal represents
    pub call_id: felt252,
    // the address of the proposer
    pub proposer: ContractAddress,
    // the execution state of the proposal
    pub execution_state: ExecutionState,
    // how many yes votes have been collected
    pub yea: u128,
    // how many no votes have been collected
    pub nay: u128,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct Config {
    // how long after a proposal is created does voting start
    pub voting_start_delay: u64,
    // the period during which votes are collected
    pub voting_period: u64,
    // over how many seconds the voting weight is averaged for proposal voting as well as creation/cancellation
    pub voting_weight_smoothing_duration: u64,
    // how many total votes must be collected for the proposal
    pub quorum: u128,
    // the minimum amount of average votes required to create a proposal
    pub proposal_creation_threshold: u128,
}

#[starknet::interface]
pub trait IGovernor<TContractState> {
    // Propose executing the given call from this contract.
    fn propose(ref self: TContractState, call: Call) -> felt252;

    // Vote on the given proposal.
    fn vote(ref self: TContractState, id: felt252, yea: bool);

    // Cancel the proposal with the given ID. Same as #cancel_at_timestamp, but uses the current timestamp for computing the voting weight.
    fn cancel(ref self: TContractState, id: felt252);

    // Cancel the proposal with the given ID. The proposal may be canceled at any time before it is executed.
    // There are two ways the proposal cancellation can be authorized:
    // - The proposer can cancel the proposal
    // - Anyone can cancel if the average voting weight of the proposer was below the proposal_creation_threshold during the voting period (at the given breach_timestamp)
    fn cancel_at_timestamp(ref self: TContractState, id: felt252, breach_timestamp: u64);

    // Execute the given proposal.
    fn execute(ref self: TContractState, id: felt252, call: Call) -> Span<felt252>;

    // Attaches the given text to the proposal. Simply emits an event containing the proposal description.
    fn describe(ref self: TContractState, id: felt252, description: ByteArray);

    // Get the configuration for this governor contract.
    fn get_staker(self: @TContractState) -> IStakerDispatcher;

    // Get the configuration for this governor contract.
    fn get_config(self: @TContractState) -> Config;

    // Get the proposal info for the given proposal id.
    fn get_proposal(self: @TContractState, id: felt252) -> ProposalInfo;
}

#[starknet::contract]
pub mod Governor {
    use core::hash::{HashStateTrait, HashStateExTrait};
    use core::num::traits::zero::{Zero};
    use core::poseidon::{PoseidonTrait};
    use governance::call_trait::{HashSerializable, CallTrait};
    use governance::staker::{IStakerDispatcherTrait};
    use starknet::{
        get_block_timestamp, get_caller_address, contract_address_const, get_contract_address
    };
    use super::{
        IStakerDispatcher, ContractAddress, Array, IGovernor, Config, ProposalInfo, Call,
        ExecutionState, ByteArray
    };


    #[derive(starknet::Event, Drop)]
    pub struct Proposed {
        pub id: felt252,
        pub proposer: ContractAddress,
        pub call: Call,
    }

    #[derive(starknet::Event, Drop, Debug, PartialEq)]
    pub struct Described {
        pub id: felt252,
        pub description: ByteArray,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Voted {
        pub id: felt252,
        pub voter: ContractAddress,
        pub weight: u128,
        pub yea: bool,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Canceled {
        pub id: felt252,
        pub breach_timestamp: u64,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Executed {
        pub id: felt252,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Proposed: Proposed,
        Described: Described,
        Voted: Voted,
        Canceled: Canceled,
        Executed: Executed,
    }

    #[storage]
    struct Storage {
        staker: IStakerDispatcher,
        config: Config,
        nonce: u64,
        proposals: LegacyMap<felt252, ProposalInfo>,
        has_voted: LegacyMap<(ContractAddress, felt252), bool>,
        latest_proposal_by_proposer: LegacyMap<ContractAddress, felt252>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, staker: IStakerDispatcher, config: Config) {
        self.staker.write(staker);
        self.config.write(config);
    }

    pub fn get_proposal_id(address: ContractAddress, nonce: u64) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::governor::Governor::get_proposal_id"))
            .update_with(address)
            .update_with(nonce)
            .finalize()
    }

    pub fn to_call_id(call: @Call) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::governor::Governor::to_call_id"))
            .update_with(call)
            .finalize()
    }

    #[abi(embed_v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn propose(ref self: ContractState, call: Call) -> felt252 {
            let nonce = self.nonce.read();
            self.nonce.write(nonce + 1);
            let id = get_proposal_id(get_contract_address(), nonce);

            let proposer = get_caller_address();
            let config = self.config.read();
            let timestamp_current = get_block_timestamp();

            let latest_proposal_id = self.latest_proposal_by_proposer.read(proposer);
            if latest_proposal_id.is_non_zero() {
                let latest_proposal_state = self.get_proposal(latest_proposal_id).execution_state;

                // if the proposal is not canceled, check that the voting for that proposal has ended
                if latest_proposal_state.canceled.is_zero() {
                    assert(
                        latest_proposal_state.created
                            + config.voting_start_delay
                            + config.voting_period <= timestamp_current,
                        'PROPOSER_HAS_ACTIVE_PROPOSAL'
                    );
                }
            }

            assert(
                self
                    .staker
                    .read()
                    .get_average_delegated_over_last(
                        delegate: proposer, period: config.voting_weight_smoothing_duration
                    ) >= config
                    .proposal_creation_threshold,
                'THRESHOLD'
            );

            self
                .proposals
                .write(
                    id,
                    ProposalInfo {
                        call_id: to_call_id(@call),
                        proposer,
                        execution_state: ExecutionState {
                            created: timestamp_current,
                            executed: Zero::zero(),
                            canceled: Zero::zero()
                        },
                        yea: 0,
                        nay: 0
                    }
                );

            self.latest_proposal_by_proposer.write(proposer, id);

            self.emit(Proposed { id, proposer, call });

            id
        }

        fn describe(ref self: ContractState, id: felt252, description: ByteArray) {
            let proposal = self.proposals.read(id);
            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.proposer == get_caller_address(), 'NOT_PROPOSER');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');
            self.emit(Described { id, description });
        }

        fn vote(ref self: ContractState, id: felt252, yea: bool) {
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');

            let config = self.config.read();
            let timestamp_current = get_block_timestamp();
            let voting_start_time = (proposal.execution_state.created + config.voting_start_delay);
            let voter = get_caller_address();
            let has_voted = self.has_voted.read((voter, id));

            assert(timestamp_current >= voting_start_time, 'VOTING_NOT_STARTED');
            assert(timestamp_current < (voting_start_time + config.voting_period), 'VOTING_ENDED');
            assert(!has_voted, 'ALREADY_VOTED');

            let weight = self
                .staker
                .read()
                .get_average_delegated(
                    delegate: voter,
                    start: voting_start_time - config.voting_weight_smoothing_duration,
                    end: voting_start_time,
                );

            if yea {
                proposal.yea = proposal.yea + weight;
            } else {
                proposal.nay = proposal.nay + weight;
            }
            self.proposals.write(id, proposal);
            self.has_voted.write((voter, id), true);

            self.emit(Voted { id, voter, weight, yea });
        }


        fn cancel(ref self: ContractState, id: felt252) {
            self.cancel_at_timestamp(id, get_block_timestamp())
        }

        fn cancel_at_timestamp(ref self: ContractState, id: felt252, breach_timestamp: u64) {
            let config = self.config.read();
            let staker = self.staker.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');

            assert(proposal.execution_state.canceled.is_zero(), 'ALREADY_CANCELED');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(breach_timestamp >= proposal.execution_state.created, 'PROPOSAL_NOT_CREATED');

            assert(
                breach_timestamp < (proposal.execution_state.created
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_ENDED'
            );

            // iff the proposer is not calling this we need to check the voting weight
            if proposal.proposer != get_caller_address() {
                // if at the given timestamp (during the voting period),
                // the average voting weight is below the proposal_creation_threshold for the proposer, it can be canceled
                assert(
                    staker
                        .get_average_delegated(
                            delegate: proposal.proposer,
                            start: breach_timestamp - config.voting_weight_smoothing_duration,
                            end: breach_timestamp
                        ) < config
                        .proposal_creation_threshold,
                    'THRESHOLD_NOT_BREACHED'
                );
            }

            proposal
                .execution_state =
                    ExecutionState {
                        created: proposal.execution_state.created,
                        // we asserted that it is not already executed
                        executed: 0,
                        canceled: get_block_timestamp()
                    };

            self.proposals.write(id, proposal);

            self.emit(Canceled { id, breach_timestamp });
        }

        fn execute(ref self: ContractState, id: felt252, call: Call) -> Span<felt252> {
            let call_id = to_call_id(@call);

            let config = self.config.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.call_id == call_id, 'CALL_ID_MISMATCH');
            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');

            let timestamp_current = get_block_timestamp();
            // we cannot tell if a proposal is executed if it is executed at timestamp 0
            // this can only happen in testing, but it makes this method locally correct
            assert(timestamp_current.is_non_zero(), 'TIMESTAMP_ZERO');

            assert(
                timestamp_current >= (proposal.execution_state.created
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_NOT_ENDED'
            );

            assert((proposal.yea + proposal.nay) >= config.quorum, 'QUORUM_NOT_MET');
            assert(proposal.yea >= proposal.nay, 'NO_MAJORITY');

            proposal
                .execution_state =
                    ExecutionState {
                        created: proposal.execution_state.created,
                        executed: timestamp_current,
                        canceled: Zero::zero()
                    };

            self.proposals.write(id, proposal);

            let data = call.execute();

            self.emit(Executed { id, });

            data
        }

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }

        fn get_staker(self: @ContractState) -> IStakerDispatcher {
            self.staker.read()
        }

        fn get_proposal(self: @ContractState, id: felt252) -> ProposalInfo {
            self.proposals.read(id)
        }
    }
}
