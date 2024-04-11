use core::array::{Array};
use core::byte_array::{ByteArray};
use core::integer::{u128_safe_divmod};
use core::option::{Option, OptionTrait};
use core::traits::{Into, TryInto};
use governance::execution_state::{ExecutionState};
use governance::staker::{IStakerDispatcher};
use starknet::account::{Call};
use starknet::{ContractAddress, storage_access::{StorePacking}};


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct ProposalInfo {
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

    // Cancel the given proposal. The proposer may cancel the proposal at any time during before or during the voting period.
    // Cancellation can happen by any address if the average voting weight is below the proposal_creation_threshold.
    fn cancel(ref self: TContractState, id: felt252);

    // Execute the given proposal.
    fn execute(ref self: TContractState, call: Call) -> Span<felt252>;

    // Attaches the given text to the proposal. Triggers an event containing the proposal description.
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
    use core::hash::{LegacyHash};
    use core::num::traits::zero::{Zero};
    use governance::call_trait::{HashCall, CallTrait};
    use governance::staker::{IStakerDispatcherTrait};
    use starknet::{get_block_timestamp, get_caller_address, contract_address_const};
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

    #[derive(starknet::Event, Drop)]
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
        proposals: LegacyMap<felt252, ProposalInfo>,
        has_voted: LegacyMap<(ContractAddress, felt252), bool>,
        latest_proposal_by_proposer: LegacyMap<ContractAddress, felt252>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, staker: IStakerDispatcher, config: Config) {
        self.staker.write(staker);
        self.config.write(config);
    }

    pub fn to_call_id(call: @Call) -> felt252 {
        LegacyHash::hash(selector!("ekubo::governance::governor::Governor::to_call_id"), call)
    }

    #[abi(embed_v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn propose(ref self: ContractState, call: Call) -> felt252 {
            let id = to_call_id(@call);
            assert(self.proposals.read(id).proposer.is_zero(), 'ALREADY_PROPOSED');

            let proposer = get_caller_address();
            let config = self.config.read();
            let timestamp_current = get_block_timestamp();

            let latest_proposal_id = self.latest_proposal_by_proposer.read(proposer);
            if latest_proposal_id.is_non_zero() {
                let latest_proposal_state = self.get_proposal(latest_proposal_id).execution_state;

                if (latest_proposal_state.canceled.is_zero()) {
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
            assert(proposal.proposer == get_caller_address(), 'NOT_PROPOSER');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(proposal.execution_state.canceled.is_zero(),'CANCELED');
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

            self.emit(Voted { id, voter, weight, yea, });
        }


        fn cancel(ref self: ContractState, id: felt252) {
            let config = self.config.read();
            let voting_token = self.staker.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');

            if (proposal.proposer != get_caller_address()) {
                // if at any point the average voting weight is below the proposal_creation_threshold for the proposer, it can be canceled
                assert(
                    voting_token
                        .get_average_delegated_over_last(
                            delegate: proposal.proposer,
                            period: config.voting_weight_smoothing_duration
                        ) < config
                        .proposal_creation_threshold,
                    'THRESHOLD_NOT_BREACHED'
                );
            }

            let timestamp_current = get_block_timestamp();

            assert(
                timestamp_current < (proposal.execution_state.created
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_ENDED'
            );

            // we know it's not executed since we check voting has not ended
            proposal
                .execution_state =
                    ExecutionState {
                        created: proposal.execution_state.created,
                        executed: 0,
                        canceled: timestamp_current
                    };

            self.proposals.write(id, proposal);

            // allows the proposer to create a new proposal
            self.latest_proposal_by_proposer.write(proposal.proposer, Zero::zero());

            self.emit(Canceled { id });
        }

        fn execute(ref self: ContractState, call: Call) -> Span<felt252> {
            let id = to_call_id(@call);

            let config = self.config.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');

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
