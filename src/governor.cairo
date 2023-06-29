use starknet::{ContractAddress};
use array::{Array};
use governance::token::{ITokenDispatcher};
use governance::timelock::{Call};

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct ProposalInfo {
    start: u64,
    yay: u128,
    nay: u128,
    abstain: u128,
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct VotingConfig {
    voting_token: ITokenDispatcher,
    voting_start_delay: u64,
    voting_period: u64,
    quorum: u128,
    min_balance_create_proposal: u64,
}

#[starknet::interface]
trait IGovernor<TStorage> {
    // Create a proposal to execute some list of calls. Proposal metadata is stored off chain.
    fn create_proposal(ref self: TStorage, calls: Array<Call>) -> felt252;
    // Get the configuration for this governor contract.
    fn get_config(self: @TStorage) -> VotingConfig;
}

#[starknet::contract]
mod Governor {
    use super::{
        ContractAddress, Array, IGovernor, ITokenDispatcher, VotingConfig, ProposalInfo, Call
    };
    use starknet::{get_block_timestamp};
    use governance::timelock::{Timelock::to_id as calls_to_id};

    #[storage]
    struct Storage {
        token: ITokenDispatcher,
        voting_config: VotingConfig,
        proposals_started: LegacyMap<felt252, ProposalInfo>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: ITokenDispatcher) {
        self.token.write(token);
    }

    #[external(v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn create_proposal(ref self: ContractState, calls: Array<Call>) -> felt252 {
            let id = calls_to_id(@calls);

            self
                .proposals_started
                .write(
                    id, ProposalInfo { start: get_block_timestamp(), yay: 0, nay: 0, abstain: 0,  }
                );

            id
        }

        fn get_config(self: @ContractState) -> VotingConfig {
            self.voting_config.read()
        }
    }
}
