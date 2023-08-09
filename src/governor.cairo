use governance::governance_token::IGovernanceTokenDispatcherTrait;
use starknet::{ContractAddress, StorePacking};
use array::{Array};
use governance::governance_token::{IGovernanceTokenDispatcher};
use starknet::account::{Call};
use option::{Option, OptionTrait};
use integer::{u128_safe_divmod, u128_as_non_zero};
use traits::{Into, TryInto};

#[derive(Copy, Drop, Serde, PartialEq)]
struct ProposalTimestamps {
    // the timestamp when the proposal was created
    creation: u64,
    // the timestamp when the proposal was executed
    executed: u64,
}

impl ProposalTimestampsStorePacking of StorePacking<ProposalTimestamps, u128> {
    fn pack(value: ProposalTimestamps) -> u128 {
        value.creation.into() + (value.executed.into() * 0x10000000000000000_u128)
    }

    fn unpack(value: u128) -> ProposalTimestamps {
        let (executed, creation) = u128_safe_divmod(value, u128_as_non_zero(0x10000000000000000));
        ProposalTimestamps {
            creation: creation.try_into().unwrap(), executed: executed.try_into().unwrap()
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct ProposalInfo {
    // the address of the proposer
    proposer: ContractAddress,
    // the relevant timestamps
    timestamps: ProposalTimestamps,
    // how many yes votes have been collected
    yes: u128,
    // how many no votes have been collected
    no: u128,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Config {
    // the token used for voting
    voting_token: IGovernanceTokenDispatcher,
    // how long after a proposal is created does voting start
    voting_start_delay: u64,
    // the period during which votes are collected
    voting_period: u64,
    // over how many seconds the voting weight is averaged for proposal voting as well as creation/cancellation
    voting_weight_smoothing_duration: u64,
    // how many total votes must be collected for the proposal
    quorum: u128,
    // the minimum amount of average votes required to create a proposal
    proposal_creation_threshold: u128,
}

#[starknet::interface]
trait IGovernor<TStorage> {
    // Propose executing the given call from this contract.
    fn propose(ref self: TStorage, call: Call) -> felt252;

    // Vote on the given proposal.
    fn vote(ref self: TStorage, id: felt252, vote: bool);

    // Cancel the given proposal. Cancellation can happen by any address if the average voting weight is below the proposal_creation_threshold.
    fn cancel(ref self: TStorage, id: felt252);

    // Execute the given proposal.
    fn execute(ref self: TStorage, call: Call) -> Span<felt252>;

    // Get the configuration for this governor contract.
    fn get_config(self: @TStorage) -> Config;

    // Get the proposal info for the given proposal id.
    fn get_proposal(self: @TStorage, id: felt252) -> ProposalInfo;
}

#[starknet::contract]
mod Governor {
    use super::{
        ContractAddress, Array, IGovernor, IGovernanceTokenDispatcher, Config, ProposalInfo, Call,
        ProposalTimestamps
    };
    use starknet::{get_block_timestamp, get_caller_address, contract_address_const};
    use governance::call_trait::{CallTrait};
    use governance::governance_token::{IGovernanceTokenDispatcherTrait};
    use zeroable::{Zeroable};

    #[storage]
    struct Storage {
        config: Config,
        proposals: LegacyMap<felt252, ProposalInfo>,
        voted: LegacyMap<(ContractAddress, felt252), bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, config: Config) {
        self.config.write(config);
    }

    #[external(v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn propose(ref self: ContractState, call: Call) -> felt252 {
            let id = call.hash();

            assert(self.proposals.read(id).proposer.is_zero(), 'ALREADY_PROPOSED');

            let config = self.config.read();

            let timestamp_current = get_block_timestamp();

            let proposer = get_caller_address();

            assert(
                config
                    .voting_token
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
                        proposer, timestamps: ProposalTimestamps {
                            creation: timestamp_current, executed: 0
                        }, yes: 0, no: 0
                    }
                );

            id
        }

        fn vote(ref self: ContractState, id: felt252, vote: bool) {
            let config = self.config.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            let timestamp_current = get_block_timestamp();
            let voting_start_time = (proposal.timestamps.creation + config.voting_start_delay);
            let voter = get_caller_address();
            let voted = self.voted.read((voter, id));

            assert(timestamp_current >= voting_start_time, 'VOTING_NOT_STARTED');
            assert(timestamp_current < (voting_start_time + config.voting_period), 'VOTING_ENDED');
            assert(!voted, 'ALREADY_VOTED');

            let weight = config
                .voting_token
                .get_average_delegated_over_last(
                    delegate: voter, period: config.voting_weight_smoothing_duration
                );

            if vote {
                proposal.yes = proposal.yes + weight;
            } else {
                proposal.no = proposal.no + weight;
            }
            self.proposals.write(id, proposal);
            self.voted.write((voter, id), true);
        }


        fn cancel(ref self: ContractState, id: felt252) {
            let config = self.config.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');

            let timestamp_current = get_block_timestamp();

            if (proposal.proposer != get_caller_address()) {
                // if at any point the average voting weight is below the proposal_creation_threshold for the proposer, it can be canceled
                assert(
                    config
                        .voting_token
                        .get_average_delegated_over_last(
                            delegate: proposal.proposer,
                            period: config.voting_weight_smoothing_duration
                        ) < config
                        .proposal_creation_threshold,
                    'THRESHOLD_NOT_BREACHED'
                );
            }

            assert(
                timestamp_current < (proposal.timestamps.creation
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_ENDED'
            );

            proposal = ProposalInfo {
                proposer: contract_address_const::<0>(), timestamps: ProposalTimestamps {
                    creation: 0, executed: 0
                }, yes: 0, no: 0
            };

            self.proposals.write(id, proposal);
        }

        fn execute(ref self: ContractState, call: Call) -> Span<felt252> {
            let id = call.hash();

            let config = self.config.read();
            let mut proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.timestamps.executed.is_zero(), 'ALREADY_EXECUTED');

            let timestamp_current = get_block_timestamp();
            // we cannot tell if a proposal is executed if it is executed at timestamp 0
            // this can only happen in testing, but it makes this method locally correct
            assert(timestamp_current.is_non_zero(), 'TIMESTAMP_ZERO');

            assert(
                timestamp_current >= (proposal.timestamps.creation
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_NOT_ENDED'
            );

            assert((proposal.yes + proposal.no) >= config.quorum, 'QUORUM_NOT_MET');
            assert(proposal.yes >= proposal.no, 'NO_MAJORITY');

            proposal.timestamps = ProposalTimestamps {
                creation: proposal.timestamps.creation, executed: timestamp_current
            };

            self.proposals.write(id, proposal);

            call.execute()
        }

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }

        fn get_proposal(self: @ContractState, id: felt252) -> ProposalInfo {
            self.proposals.read(id)
        }
    }
}
