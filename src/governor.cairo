use governance::execution_state::{ExecutionState};
use governance::staker::{IStakerDispatcher};
use starknet::account::{Call};
use starknet::{ClassHash, ContractAddress, EthAddress};

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct ProposalInfo {
    // The hash of the set of calls that are executed in this proposal
    pub calls_hash: felt252,
    // The address of the proposer
    pub proposer: ContractAddress,
    // The execution state of the proposal
    pub execution_state: ExecutionState,
    // How many yes votes have been collected
    pub yea: u128,
    // How many no votes have been collected
    pub nay: u128,
    // The version of the config that this proposal was created with
    pub config_version: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct Config {
    // How long after a proposal is created does voting start
    pub voting_start_delay: u64,
    // The period during which votes are collected
    pub voting_period: u64,
    // Over how many seconds the voting weight is averaged for proposal voting as well as
    // creation/cancellation
    pub voting_weight_smoothing_duration: u64,
    // How many total votes must be collected for the proposal
    pub quorum: u128,
    // The minimum amount of average votes required to create a proposal
    pub proposal_creation_threshold: u128,
    // How much time must pass after the end of a voting period before the proposal can be executed
    pub execution_delay: u64,
    // The amount of time after the execution delay that the proposal may be executed
    pub execution_window: u64,
}

#[starknet::interface]
pub trait IGovernor<TContractState> {
    // Proposes executing the given call from this contract.
    fn propose(ref self: TContractState, calls: Span<Call>) -> felt252;

    // Votes on the given proposal.
    fn vote(ref self: TContractState, id: felt252, yea: bool);

    // Cancels the proposal with the given ID. Only callable by the proposer.
    fn cancel(ref self: TContractState, id: felt252);

    // Execute the given proposal.
    fn execute(ref self: TContractState, id: felt252, calls: Span<Call>) -> Span<Span<felt252>>;

    // Attaches the given text to the proposal. Simply emits an event containing the proposal
    // description.
    fn describe(ref self: TContractState, id: felt252, description: ByteArray);

    // Combines propose and describe methods.
    fn propose_and_describe(
        ref self: TContractState, calls: Span<Call>, description: ByteArray,
    ) -> felt252;

    // Gets the staker that is used by this governor contract.
    fn get_staker(self: @TContractState) -> IStakerDispatcher;

    // Gets the latest configuration for this governor contract.
    fn get_config(self: @TContractState) -> Config;

    // Gets the latest configuration for this governor contract and its config version ID.
    fn get_config_with_version(self: @TContractState) -> (Config, u64);

    // Gets the configuration with the given version ID.
    fn get_config_version(self: @TContractState, version: u64) -> Config;

    // Gets the proposal info for the given proposal id.
    fn get_proposal(self: @TContractState, id: felt252) -> ProposalInfo;

    // Gets the proposal and the config version with which it was created.
    fn get_proposal_with_config(self: @TContractState, id: felt252) -> (ProposalInfo, Config);

    // Returns the vote cast by the given voter on the given proposal ID.
    // - 0 means not voted, or proposal does not exist
    // - 3 means voted in favor
    // - 1 means voted against
    fn get_vote(self: @TContractState, id: felt252, voter: ContractAddress) -> u8;

    // Changes the configuration of the governor. Only affects proposals created after the
    // configuration change. Must be called by self, e.g. via a proposal.
    fn reconfigure(ref self: TContractState, config: Config) -> u64;

    // Replaces the code at this address. This must be self-called via a proposal.
    fn upgrade(ref self: TContractState, class_hash: ClassHash);

    // Sends a message to L1 via syscall
    fn send_message_to_l1(self: @TContractState, to_address: EthAddress, payload: Span<felt252>);
}

#[starknet::contract(account)]
pub mod Governor {
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::zero::{Zero};
    use core::poseidon::{PoseidonTrait};
    use governance::call_trait::{CallTrait, HashSerializable};
    use governance::staker::{IStakerDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{
        AccountContract, get_block_timestamp, get_caller_address, get_contract_address, get_tx_info,
        syscalls::{replace_class_syscall, send_message_to_l1_syscall},
    };
    use super::{
        Call, ClassHash, Config, ContractAddress, ExecutionState, IGovernor, IStakerDispatcher,
        ProposalInfo, EthAddress,
    };


    #[derive(starknet::Event, Drop)]
    pub struct Proposed {
        pub id: felt252,
        pub proposer: ContractAddress,
        pub calls: Span<Call>,
        pub config_version: u64,
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
    }

    #[derive(starknet::Event, Drop, PartialEq, Debug)]
    pub struct Executed {
        pub id: felt252,
        pub result_data: Span<Span<felt252>>,
    }

    #[derive(starknet::Event, Drop, PartialEq, Debug)]
    pub struct Reconfigured {
        pub new_config: Config,
        pub version: u64,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Proposed: Proposed,
        Described: Described,
        Voted: Voted,
        Canceled: Canceled,
        Executed: Executed,
        Reconfigured: Reconfigured,
    }

    #[storage]
    struct Storage {
        staker: IStakerDispatcher,
        config_versions: Map<u64, Config>,
        latest_config_version: u64,
        nonce: u64,
        proposals: Map<felt252, ProposalInfo>,
        latest_proposal_by_proposer: Map<ContractAddress, felt252>,
        vote: Map<(felt252, ContractAddress), u8>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, staker: IStakerDispatcher, config: Config) {
        self.staker.write(staker);

        self.config_versions.write(0, config);
        self.emit(Reconfigured { new_config: config, version: 0 });
    }

    pub fn get_proposal_id(address: ContractAddress, nonce: u64) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::governor::Governor::get_proposal_id"))
            .update_with(address)
            .update_with(nonce)
            .finalize()
    }

    pub fn hash_calls(call: @Span<Call>) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::governor::Governor::hash_calls"))
            .update_with(call)
            .finalize()
    }

    #[generate_trait]
    impl GovernorInternal of GovernorInternalTrait {
        fn check_self_call(self: @ContractState) {
            assert(get_caller_address() == get_contract_address(), 'SELF_CALL_ONLY');
        }
    }

    #[abi(embed_v0)]
    impl GovernorImpl of IGovernor<ContractState> {
        fn propose(ref self: ContractState, calls: Span<Call>) -> felt252 {
            let nonce = self.nonce.read();
            self.nonce.write(nonce + 1);
            let id = get_proposal_id(get_contract_address(), nonce);

            let proposer = get_caller_address();
            let (config, config_version) = self.get_config_with_version();
            let timestamp_current = get_block_timestamp();

            let latest_proposal_id = self.latest_proposal_by_proposer.read(proposer);
            if latest_proposal_id.is_non_zero() {
                let latest_proposal_state = self.get_proposal(latest_proposal_id).execution_state;

                // if the proposal is not canceled, check that the voting for that proposal has
                // ended
                if latest_proposal_state.canceled.is_zero() {
                    assert(
                        latest_proposal_state.created
                            + config.voting_start_delay
                            + config.voting_period <= timestamp_current,
                        'PROPOSER_HAS_ACTIVE_PROPOSAL',
                    );
                }
            }

            assert(
                self
                    .get_staker()
                    .get_average_delegated_over_last(
                        delegate: proposer, period: config.voting_weight_smoothing_duration,
                    ) >= config
                    .proposal_creation_threshold,
                'THRESHOLD',
            );

            self
                .proposals
                .write(
                    id,
                    ProposalInfo {
                        calls_hash: hash_calls(@calls),
                        proposer,
                        execution_state: ExecutionState {
                            created: timestamp_current,
                            executed: Zero::zero(),
                            canceled: Zero::zero(),
                        },
                        yea: 0,
                        nay: 0,
                        config_version,
                    },
                );

            self.latest_proposal_by_proposer.write(proposer, id);

            self.emit(Proposed { id, proposer, calls, config_version });

            id
        }

        fn describe(ref self: ContractState, id: felt252, description: ByteArray) {
            let proposal = self.get_proposal(id);
            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.proposer == get_caller_address(), 'NOT_PROPOSER');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');
            self.emit(Described { id, description });
        }

        fn propose_and_describe(
            ref self: ContractState, calls: Span<Call>, description: ByteArray,
        ) -> felt252 {
            let id = self.propose(calls);
            self.describe(id, description);

            id
        }

        fn vote(ref self: ContractState, id: felt252, yea: bool) {
            let (mut proposal, config) = self.get_proposal_with_config(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');

            let timestamp_current = get_block_timestamp();
            let voting_start_time = (proposal.execution_state.created + config.voting_start_delay);
            let voter = get_caller_address();
            let past_vote = self.vote.read((id, voter));

            assert(timestamp_current >= voting_start_time, 'VOTING_NOT_STARTED');
            assert(timestamp_current < (voting_start_time + config.voting_period), 'VOTING_ENDED');
            assert(past_vote.is_zero(), 'ALREADY_VOTED');

            let weight = self
                .get_staker()
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
            self.vote.write((id, voter), if yea {
                3
            } else {
                1
            });

            self.emit(Voted { id, voter, weight, yea });
        }

        fn cancel(ref self: ContractState, id: felt252) {
            let (mut proposal, config) = self.get_proposal_with_config(id);

            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.proposer == get_caller_address(), 'PROPOSER_ONLY');
            assert(proposal.execution_state.canceled.is_zero(), 'ALREADY_CANCELED');

            // this is prevented so that proposers cannot grief voters by creating proposals that
            // they plan to cancel after the result is known
            assert(
                get_block_timestamp() < (proposal.execution_state.created
                    + config.voting_start_delay),
                'VOTING_STARTED',
            );

            proposal
                .execution_state =
                    ExecutionState {
                        created: proposal.execution_state.created,
                        // we asserted that executed is zero
                        executed: 0,
                        canceled: get_block_timestamp(),
                    };

            self.proposals.write(id, proposal);

            self.emit(Canceled { id });
        }

        fn execute(
            ref self: ContractState, id: felt252, mut calls: Span<Call>,
        ) -> Span<Span<felt252>> {
            let calls_hash = hash_calls(@calls);

            let (mut proposal, config) = self.get_proposal_with_config(id);

            assert(proposal.calls_hash == calls_hash, 'CALLS_HASH_MISMATCH');
            assert(proposal.proposer.is_non_zero(), 'DOES_NOT_EXIST');
            assert(proposal.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(proposal.execution_state.canceled.is_zero(), 'PROPOSAL_CANCELED');

            let timestamp_current = get_block_timestamp();
            // we cannot tell if a proposal is executed if it is executed at timestamp 0
            // this can only happen in testing, but it makes this method locally correct
            assert(timestamp_current.is_non_zero(), 'TIMESTAMP_ZERO');

            let voting_end = proposal.execution_state.created
                + config.voting_start_delay
                + config.voting_period;
            assert(timestamp_current >= voting_end, 'VOTING_NOT_ENDED');

            let window_start = voting_end + config.execution_delay;
            assert(timestamp_current >= window_start, 'EXECUTION_WINDOW_NOT_STARTED');

            let window_end = window_start + config.execution_window;
            assert(timestamp_current < window_end, 'EXECUTION_WINDOW_OVER');

            assert(proposal.yea >= config.quorum, 'QUORUM_NOT_MET');
            assert(proposal.yea >= proposal.nay, 'NO_MAJORITY');

            proposal
                .execution_state =
                    ExecutionState {
                        created: proposal.execution_state.created,
                        executed: timestamp_current,
                        canceled: Zero::zero(),
                    };

            self.proposals.write(id, proposal);

            let mut results: Array<Span<felt252>> = array![];

            while let Option::Some(call) = calls.pop_front() {
                results.append(call.execute());
            };

            let result_span = results.span();

            self.emit(Executed { id, result_data: result_span });

            result_span
        }

        fn get_config(self: @ContractState) -> Config {
            self.get_config_version(self.latest_config_version.read())
        }

        fn get_config_with_version(self: @ContractState) -> (Config, u64) {
            let config_version = self.latest_config_version.read();
            (self.get_config_version(config_version), config_version)
        }

        fn get_config_version(self: @ContractState, version: u64) -> Config {
            self.config_versions.read(version)
        }

        fn get_staker(self: @ContractState) -> IStakerDispatcher {
            self.staker.read()
        }

        fn get_proposal(self: @ContractState, id: felt252) -> ProposalInfo {
            self.proposals.read(id)
        }

        fn get_proposal_with_config(self: @ContractState, id: felt252) -> (ProposalInfo, Config) {
            let proposal = self.get_proposal(id);
            let config = self.get_config_version(proposal.config_version);

            (proposal, config)
        }

        fn get_vote(self: @ContractState, id: felt252, voter: ContractAddress) -> u8 {
            self.vote.read((id, voter))
        }

        fn reconfigure(ref self: ContractState, config: Config) -> u64 {
            self.check_self_call();

            let version = self.latest_config_version.read() + 1;
            self.config_versions.write(version, config);
            self.latest_config_version.write(version);
            self.emit(Reconfigured { new_config: config, version });

            version
        }

        fn upgrade(ref self: ContractState, class_hash: ClassHash) {
            self.check_self_call();

            replace_class_syscall(class_hash).unwrap();
        }

        fn send_message_to_l1(
            self: @ContractState, to_address: EthAddress, payload: Span<felt252>,
        ) {
            self.check_self_call();

            send_message_to_l1_syscall(to_address.into(), payload).expect('SYSCALL_FAILED')
        }
    }

    // This implementation exists solely for the purpose of allowing simulation of calls from the
    // governor with the flag to skip validation
    #[abi(embed_v0)]
    impl GovernorAccountContractForSimulation of AccountContract<ContractState> {
        fn __validate_declare__(self: @ContractState, class_hash: felt252) -> felt252 {
            panic!("Not allowed");
            0
        }
        fn __validate__(ref self: ContractState, calls: Array<Call>) -> felt252 {
            panic!("Not allowed");
            0
        }
        fn __execute__(ref self: ContractState, mut calls: Array<Call>) -> Array<Span<felt252>> {
            assert(get_caller_address().is_zero(), 'Invalid caller');
            let tx_version = get_tx_info().unbox().version.into();
            assert(
                tx_version == 0x100000000000000000000000000000001
                    || tx_version == 0x100000000000000000000000000000003,
                'Invalid TX version',
            );
            let mut results: Array<Span<felt252>> = array![];
            while let Option::Some(call) = calls.pop_front() {
                results.append(call.execute());
            };
            results
        }
    }
}
