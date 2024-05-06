use core::option::OptionTrait;
use core::result::ResultTrait;
use core::traits::TryInto;
use governance::execution_state::{ExecutionState};
use governance::utils::u64_tuple_storage::{TwoU64TupleStorePacking};
use starknet::account::{Call};
use starknet::class_hash::{ClassHash};
use starknet::contract_address::{ContractAddress};
use starknet::storage_access::{StorePacking};

#[derive(Copy, Drop, Serde)]
pub struct Config {
    pub delay: u64,
    pub window: u64,
}

pub(crate) impl ConfigStorePacking of StorePacking<Config, u128> {
    fn pack(value: Config) -> u128 {
        TwoU64TupleStorePacking::pack((value.delay, value.window))
    }

    fn unpack(value: u128) -> Config {
        let (delay, window) = TwoU64TupleStorePacking::unpack(value);
        Config { delay, window }
    }
}

#[starknet::interface]
pub trait ITimelock<TContractState> {
    // Queue a list of calls to be executed after the delay. Only the owner may call this.
    fn queue(ref self: TContractState, calls: Span<Call>) -> felt252;

    // Cancel a queued proposal before it is executed. Only the owner may call this.
    fn cancel(ref self: TContractState, id: felt252);

    // Execute a list of calls that have previously been queued. Anyone may call this.
    fn execute(ref self: TContractState, id: felt252, calls: Span<Call>) -> Span<Span<felt252>>;

    // Return the execution window, i.e. the start and end timestamp in which the call can be executed
    fn get_execution_window(self: @TContractState, id: felt252) -> ExecutionWindow;

    // Get the current owner
    fn get_owner(self: @TContractState) -> ContractAddress;

    // Returns the delay and the window for call execution
    fn get_config(self: @TContractState) -> Config;

    // Transfer ownership, i.e. the address that can queue and cancel calls. This must be self-called via #queue.
    fn transfer(ref self: TContractState, to: ContractAddress);

    // Configure the delay and the window for call execution. This must be self-called via #queue.
    fn configure(ref self: TContractState, config: Config);

    // Replace the code at this address. This must be self-called via #queue.
    fn upgrade(ref self: TContractState, class_hash: ClassHash);
}

#[derive(Copy, Drop, Serde)]
pub struct ExecutionWindow {
    pub earliest: u64,
    pub latest: u64
}

#[starknet::contract]
pub mod Timelock {
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::zero::{Zero};
    use core::poseidon::{PoseidonTrait, HashState as PoseidonHashState};
    use core::result::{ResultTrait};
    use governance::call_trait::{CallTrait, HashSerializable};
    use starknet::{
        get_caller_address, get_contract_address, SyscallResult,
        syscalls::{call_contract_syscall, replace_class_syscall}, get_block_timestamp
    };
    use super::{
        ClassHash, ITimelock, ContractAddress, Call, Config, ExecutionState, ConfigStorePacking,
        ExecutionWindow
    };


    #[derive(starknet::Event, Drop)]
    pub struct Queued {
        pub id: felt252,
        pub calls: Span<Call>,
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
        Queued: Queued,
        Canceled: Canceled,
        Executed: Executed,
    }

    #[derive(Copy, Drop, starknet::Store)]
    struct BatchState {
        calls_hash: felt252,
        execution_state: ExecutionState,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        config: Config,
        batch_state: LegacyMap<felt252, BatchState>,
        nonce: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, config: Config) {
        self.owner.write(owner);
        self.config.write(config);
    }

    pub fn hash_calls(mut calls: Span<Call>) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::timelock::Timelock::hash_calls"))
            .update_with(@calls)
            .finalize()
    }

    pub fn get_batch_id(address: ContractAddress, nonce: u64) -> felt252 {
        PoseidonTrait::new()
            .update(selector!("governance::timelock::Timelock::get_batch_id"))
            .update_with(address)
            .update_with(nonce)
            .finalize()
    }

    #[generate_trait]
    impl TimelockInternal of TimelockInternalTrait {
        fn check_owner(self: @ContractState) {
            assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
        }

        fn check_self_call(self: @ContractState) {
            assert(get_caller_address() == get_contract_address(), 'SELF_CALL_ONLY');
        }
    }

    #[abi(embed_v0)]
    impl TimelockImpl of ITimelock<ContractState> {
        fn queue(ref self: ContractState, calls: Span<Call>) -> felt252 {
            self.check_owner();

            let nonce = self.nonce.read();
            self.nonce.write(nonce + 1);

            let id = get_batch_id(get_contract_address(), nonce);

            self
                .batch_state
                .write(
                    id,
                    BatchState {
                        calls_hash: hash_calls(calls),
                        execution_state: ExecutionState {
                            created: get_block_timestamp(), executed: 0, canceled: 0
                        }
                    }
                );

            self.emit(Queued { id, calls });

            id
        }

        fn cancel(ref self: ContractState, id: felt252) {
            self.check_owner();

            let batch_state = self.batch_state.read(id);
            assert(batch_state.execution_state.created.is_non_zero(), 'DOES_NOT_EXIST');
            assert(batch_state.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(batch_state.execution_state.canceled.is_zero(), 'ALREADY_CANCELED');

            self
                .batch_state
                .write(
                    id,
                    BatchState {
                        calls_hash: batch_state.calls_hash,
                        execution_state: ExecutionState {
                            created: batch_state.execution_state.created,
                            executed: 0,
                            canceled: get_block_timestamp()
                        }
                    }
                );

            self.emit(Canceled { id });
        }

        fn execute(
            ref self: ContractState, id: felt252, mut calls: Span<Call>
        ) -> Span<Span<felt252>> {
            let batch_state = self.batch_state.read(id);

            let calls_hash = hash_calls(calls);

            assert(batch_state.calls_hash == calls_hash, 'CALLS_HASH_MISMATCH');
            assert(batch_state.execution_state.executed.is_zero(), 'ALREADY_EXECUTED');
            assert(batch_state.execution_state.canceled.is_zero(), 'HAS_BEEN_CANCELED');

            let execution_window = self.get_execution_window(id);
            let time_current = get_block_timestamp();

            assert(time_current >= execution_window.earliest, 'TOO_EARLY');
            assert(time_current < execution_window.latest, 'TOO_LATE');

            self
                .batch_state
                .write(
                    id,
                    BatchState {
                        calls_hash,
                        execution_state: ExecutionState {
                            created: batch_state.execution_state.created,
                            executed: time_current,
                            canceled: batch_state.execution_state.canceled
                        }
                    }
                );

            let mut results: Array<Span<felt252>> = ArrayTrait::new();

            while let Option::Some(call) = calls.pop_front() {
                results.append(call.execute());
            };

            self.emit(Executed { id });

            results.span()
        }

        fn get_execution_window(self: @ContractState, id: felt252) -> ExecutionWindow {
            let created = self.batch_state.read(id).execution_state.created;

            // this prevents the 0 timestamp for created from being considered valid and also executed
            assert(created.is_non_zero(), 'DOES_NOT_EXIST');

            let config = self.get_config();

            let earliest = created + config.delay;

            let latest = earliest + config.window;

            ExecutionWindow { earliest, latest }
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }

        fn transfer(ref self: ContractState, to: ContractAddress) {
            self.check_self_call();

            self.owner.write(to);
        }

        fn configure(ref self: ContractState, config: Config) {
            self.check_self_call();

            self.config.write(config);
        }

        fn upgrade(ref self: ContractState, class_hash: ClassHash) {
            self.check_self_call();

            replace_class_syscall(class_hash).unwrap();
        }
    }
}
