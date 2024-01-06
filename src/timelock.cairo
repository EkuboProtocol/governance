use core::option::OptionTrait;
use core::traits::TryInto;
use core::result::ResultTrait;
use starknet::{ContractAddress};
use starknet::account::{Call};
use core::integer::{u128_to_felt252, u64_try_from_felt252};
use starknet::storage_access::{StorePacking};

#[starknet::interface]
trait ITimelock<TStorage> {
    // Queue a list of calls to be executed after the delay. Only the owner may call this.
    fn queue(ref self: TStorage, calls: Span<Call>) -> felt252;

    // Cancel a queued proposal before it is executed. Only the owner may call this.
    fn cancel(ref self: TStorage, id: felt252);

    // Execute a list of calls that have previously been queued. Anyone may call this.
    fn execute(ref self: TStorage, calls: Span<Call>) -> Array<Span<felt252>>;

    // Return the execution window, i.e. the start and end timestamp in which the call can be executed
    fn get_execution_window(self: @TStorage, id: felt252) -> ExecutionWindow;

    // Get the current owner
    fn get_owner(self: @TStorage) -> ContractAddress;

    // Returns the delay and the window for call execution
    fn get_configuration(self: @TStorage) -> DelayAndWindow;

    // Transfer ownership, i.e. the address that can queue and cancel calls. This must be self-called via #queue.
    fn transfer(ref self: TStorage, to: ContractAddress);
    // Configure the delay and the window for call execution. This must be self-called via #queue.
    fn configure(ref self: TStorage, delay_and_window: DelayAndWindow);
}


const U64_MASK: u128 = 0xFFFFFFFFFFFFFFFF;
const TWO_POW_64: u128 = 0x10000000000000000;

#[derive(Copy, Drop, Serde)]
struct ExecutionState {
    started: u64,
    executed: u64,
    canceled: u64
}

impl ExecutionStateStorePacking of StorePacking<ExecutionState, felt252> {
    fn pack(value: ExecutionState) -> felt252 {
        u256 {
            low: value.started.into()+value.executed.into()*TWO_POW_64,
            high: value.canceled.into()
        }.try_into().unwrap()
    }
    fn unpack(value: felt252) -> ExecutionState {
        let u256_value: u256 = value.into();
        ExecutionState {
            started: (u256_value.low & U64_MASK).try_into().unwrap(), 
            executed: (u256_value.low/TWO_POW_64).try_into().unwrap(), 
            canceled: (u256_value.high).try_into().unwrap()
        }
    }
}

#[derive(Copy, Drop, Serde)]
struct DelayAndWindow {
    delay: u64,
    window: u64
}

impl DelayAndWindowStorePacking of StorePacking<DelayAndWindow, felt252> {
    fn pack(value: DelayAndWindow) -> felt252 {
        (value.delay.into()+value.window.into()*TWO_POW_64).into()
    }
    fn unpack(value: felt252) -> DelayAndWindow {
        let u256_value: u256 = value.into();
        DelayAndWindow {
            delay: (u256_value.low & U64_MASK).try_into().unwrap(), 
            window: (u256_value.low/TWO_POW_64).try_into().unwrap(), 
        }
    }
}

#[derive(Copy, Drop, Serde)]
struct ExecutionWindow {
    earliest: u64,
    latest: u64
}

impl ExecutionWindowStorePacking of StorePacking<ExecutionWindow, felt252> {
    fn pack(value: ExecutionWindow) -> felt252 {
        (value.earliest.into()+value.latest.into()*TWO_POW_64).into()
    }
    fn unpack(value: felt252) -> ExecutionWindow {
        let u256_value: u256 = value.into();
        ExecutionWindow {
            earliest: (u256_value.low & U64_MASK).try_into().unwrap(), 
            latest: (u256_value.low/TWO_POW_64).try_into().unwrap(), 
        }
    }
}


#[starknet::contract]
mod Timelock {
    use super::{ITimelock, ContractAddress, Call, DelayAndWindow, ExecutionState, DelayAndWindowStorePacking, ExecutionStateStorePacking, ExecutionWindow, ExecutionWindowStorePacking};
    use governance::call_trait::{CallTrait, HashCall};
    use hash::{LegacyHash};
    use array::{ArrayTrait, SpanTrait};
    use starknet::{
        get_caller_address, get_contract_address, SyscallResult, syscalls::call_contract_syscall,
        ContractAddressIntoFelt252, get_block_timestamp
    };
    use result::{ResultTrait};
    use traits::{Into};
    use zeroable::{Zeroable};

    #[derive(starknet::Event, Drop)]
    struct Queued {
        id: felt252,
        calls: Span<Call>,
    }

    #[derive(starknet::Event, Drop)]
    struct Canceled {
        id: felt252,
    }

    #[derive(starknet::Event, Drop)]
    struct Executed {
        id: felt252,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Queued: Queued,
        Canceled: Canceled,
        Executed: Executed,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        delay_and_window: DelayAndWindow,
        // started_executed_canceled
        execution_state: LegacyMap<felt252, ExecutionState>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, delay_and_window: DelayAndWindow) {
        self.owner.write(owner);
        self.delay_and_window.write(delay_and_window);
    }

    // Take a list of calls and convert it to a unique identifier for the execution
    // Two lists of calls will always have the same ID if they are equivalent
    // A list of calls can only be queued and executed once. To make 2 different calls, add an empty call.
    fn to_id(mut calls: Span<Call>) -> felt252 {
        let mut state = 0;
        loop {
            match calls.pop_front() {
                Option::Some(call) => { state = LegacyHash::hash(state, call) },
                Option::None => { break state; }
            };
        }
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

    #[external(v0)]
    impl TimelockImpl of ITimelock<ContractState> {
        fn queue(ref self: ContractState, calls: Span<Call>) -> felt252 {
            self.check_owner();

            let id = to_id(calls);
            let execution_state = self.execution_state.read(id);

            assert(execution_state.started.is_zero(), 'ALREADY_QUEUED');

            self.execution_state.write(id, ExecutionState{started: get_block_timestamp(), executed: execution_state.executed, canceled: execution_state.canceled});

            self.emit(Queued { id, calls, });

            id
        }

        fn cancel(ref self: ContractState, id: felt252) {
            self.check_owner();
            let execution_state = self.execution_state.read(id);
            assert(execution_state.started.is_non_zero(), 'DOES_NOT_EXIST');
            assert(execution_state.executed.is_zero(), 'ALREADY_EXECUTED');

            self.execution_state.write(id, ExecutionState {started: 0, executed: execution_state.executed, canceled: execution_state.canceled});

            self.emit(Canceled { id, });
        }

        fn execute(ref self: ContractState, mut calls: Span<Call>) -> Array<Span<felt252>> {
            let id = to_id(calls);

            let execution_state = self.execution_state.read(id);

            assert(execution_state.executed.is_zero(), 'ALREADY_EXECUTED');

            let execution_window = self.get_execution_window(id);
            let time_current = get_block_timestamp();

            assert(time_current >= execution_window.earliest, 'TOO_EARLY');
            assert(time_current < execution_window.latest, 'TOO_LATE');

            self.execution_state.write(id, ExecutionState {started: execution_state.started, executed: time_current, canceled: execution_state.canceled});

            let mut results: Array<Span<felt252>> = ArrayTrait::new();

            loop {
                match calls.pop_front() {
                    Option::Some(call) => { results.append(call.execute()); },
                    Option::None => { break; }
                };
            };

            self.emit(Executed { id, });

            results
        }

        fn get_execution_window(self: @ContractState, id: felt252) -> ExecutionWindow {
            let start_time = self.execution_state.read(id).started;

            // this is how we prevent the 0 timestamp from being considered valid
            assert(start_time != 0, 'DOES_NOT_EXIST');

            let configuration = (self.get_configuration());

            let earliest = start_time + configuration.delay;
            
            let latest = earliest + configuration.window;

            ExecutionWindow {earliest: earliest, latest: latest}
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_configuration(self: @ContractState) -> DelayAndWindow {
            self.delay_and_window.read()
        }

        fn transfer(ref self: ContractState, to: ContractAddress) {
            self.check_self_call();

            self.owner.write(to);
        }

        fn configure(ref self: ContractState, delay_and_window: DelayAndWindow) {
            self.check_self_call();

            self.delay_and_window.write(delay_and_window);
        }
    }
}
