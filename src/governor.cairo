use governance::token::ITokenDispatcherTrait;
use starknet::{ContractAddress};
use array::{Array};
use governance::token::{ITokenDispatcher};
use governance::types::{Call};

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
    // over how many seconds the voting weight is averaged for proposal voting and creation/cancellation
    voting_weight_smoothing_duration: u64,
    // how many total votes must be collected for the proposal
    quorum: u128,
    // the minimum amount of tokens required to create a proposal
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
    fn execute(ref self: TStorage, call: Call);

    // Get the configuration for this governor contract.
    fn get_config(self: @TStorage) -> Config;
}

#[starknet::contract]
mod Governor {
    use super::{ContractAddress, Array, IGovernor, ITokenDispatcher, Config, ProposalInfo, Call};
    use starknet::{get_block_timestamp, get_caller_address};
    use governance::types::{CallTrait};
    use governance::token::{ITokenDispatcherTrait};

    #[storage]
    struct Storage {
        config: Config,
        proposals_started: LegacyMap<felt252, ProposalInfo>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, config: Config) {
        self.config.write(config);
    }

    #[external(v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn propose(ref self: ContractState, call: Call) -> felt252 {
            let id = call.hash();

            let config = self.config.read();

            let timestamp_current = get_block_timestamp();
            let start = timestamp_current - config.voting_weight_smoothing_duration;

            let proposer = get_caller_address();

            assert(
                config
                    .voting_token
                    .get_average_delegated(proposer, start, timestamp_current) >= config
                    .proposal_creation_threshold,
                'THRESHOLD'
            );

            self
                .proposals_started
                .write(
                    id,
                    ProposalInfo {
                        proposer, creation_timestamp: timestamp_current, yes: 0, no: 0, 
                    }
                );

            id
        }

        fn vote(ref self: ContractState, id: felt252, vote: bool) {}
        fn cancel(ref self: ContractState, id: felt252) {}
        fn execute(ref self: ContractState, call: Call) {}

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }
    }
}
