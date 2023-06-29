use starknet::{ContractAddress};
use array::{Array};
use governance::token::{ITokenDispatcher};
use governance::types::{Call};

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct ProposalInfo {
    // when the proposal was created
    creation_timestamp: u64,
    // how many yes votes has been collected
    yes: u128,
    // how many no votes has been collected
    no: u128,
    // how many votes have been abstained
    abstain: u128,
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
    min_balance_create_proposal: u64,
}

#[starknet::interface]
trait IGovernor<TStorage> {
    // Create a proposal to execute a single call from this contract.
    fn create_proposal(ref self: TStorage, call: Call) -> felt252;
    // Get the configuration for this governor contract.
    fn get_config(self: @TStorage) -> Config;
}

#[starknet::contract]
mod Governor {
    use super::{ContractAddress, Array, IGovernor, ITokenDispatcher, Config, ProposalInfo, Call};
    use starknet::{get_block_timestamp};
    use governance::types::{CallTrait};

    #[storage]
    struct Storage {
        token: ITokenDispatcher,
        voting_config: Config,
        proposals_started: LegacyMap<felt252, ProposalInfo>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: ITokenDispatcher) {
        self.token.write(token);
    }

    #[external(v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn create_proposal(ref self: ContractState, call: Call) -> felt252 {
            let id = call.hash();

            let config = self.voting_config.read();

            self
                .proposals_started
                .write(
                    id,
                    ProposalInfo {
                        creation_timestamp: get_block_timestamp(), yes: 0, no: 0, abstain: 0, 
                    }
                );

            id
        }

        fn get_config(self: @ContractState) -> Config {
            self.voting_config.read()
        }
    }
}
