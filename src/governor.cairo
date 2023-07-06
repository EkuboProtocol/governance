use governance::token::ITokenDispatcherTrait;
use starknet::{ContractAddress};
use array::{Array};
use governance::token::{ITokenDispatcher};
use starknet::account::{Call};

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct ProposalInfo {
    proposer: ContractAddress,
    // when the proposal was created
    creation_timestamp: u64,
    // how many yes votes has been collected
    yes: u128,
    // how many no votes has been collected
    no: u128,
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Config {
    // the token used for voting
    voting_token: ITokenDispatcher,
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
}

#[starknet::contract]
mod Governor {
    use super::{ContractAddress, Array, IGovernor, ITokenDispatcher, Config, ProposalInfo, Call};
    use starknet::{get_block_timestamp, get_caller_address, contract_address_const};
    use governance::call_trait::{CallTrait};
    use governance::token::{ITokenDispatcherTrait};
    use zeroable::{Zeroable};

    #[storage]
    struct Storage {
        config: Config,
        proposals: LegacyMap<felt252, ProposalInfo>,
        voted: LegacyMap<(ContractAddress, felt252), bool>,
        executed: LegacyMap<felt252, bool>,
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
                        proposer, creation_timestamp: timestamp_current, yes: 0, no: 0, 
                    }
                );

            id
        }

        fn vote(ref self: ContractState, id: felt252, vote: bool) {
            let config = self.config.read();
            let proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            let timestamp_current = get_block_timestamp();
            let voting_start_time = (proposal.creation_timestamp + config.voting_start_delay);
            let voter = get_caller_address();

            assert(timestamp_current >= voting_start_time, 'VOTING_NOT_STARTED');
            assert(timestamp_current < (voting_start_time + config.voting_period), 'VOTING_ENDED');
            assert(!self.voted.read((voter, id)), 'ALREADY_VOTED');

            let weight = config
                .voting_token
                .get_average_delegated_over_last(
                    delegate: voter, period: config.voting_weight_smoothing_duration
                );

            self
                .proposals
                .write(
                    id,
                    if vote {
                        ProposalInfo {
                            proposer: proposal.proposer,
                            creation_timestamp: proposal.creation_timestamp,
                            yes: proposal.yes + weight,
                            no: proposal.no,
                        }
                    } else {
                        ProposalInfo {
                            proposer: proposal.proposer,
                            creation_timestamp: proposal.creation_timestamp,
                            yes: proposal.yes,
                            no: proposal.no + weight,
                        }
                    }
                );
        }


        fn cancel(ref self: ContractState, id: felt252) {
            let config = self.config.read();
            let proposal = self.proposals.read(id);

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
                timestamp_current < (proposal.creation_timestamp
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_ENDED'
            );

            self
                .proposals
                .write(
                    id,
                    ProposalInfo {
                        proposer: contract_address_const::<0>(),
                        creation_timestamp: 0,
                        yes: 0,
                        no: 0,
                    }
                );
        }

        fn execute(ref self: ContractState, call: Call) -> Span<felt252> {
            let id = call.hash();

            let config = self.config.read();
            let proposal = self.proposals.read(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(!self.executed.read(id), 'ALREADY_EXECUTED');

            let timestamp_current = get_block_timestamp();

            assert(
                timestamp_current >= (proposal.creation_timestamp
                    + config.voting_start_delay
                    + config.voting_period),
                'VOTING_NOT_ENDED'
            );

            assert((proposal.yes + proposal.no) >= config.quorum, 'QUORUM_NOT_MET');
            assert(proposal.yes >= proposal.no, 'NO_MAJORITY');

            self.executed.write(id, true);

            call.execute()
        }

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }
    }
}
