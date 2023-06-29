use core::result::ResultTrait;
use starknet::{ContractAddress};
use governance::types::{Call};

#[starknet::interface]
trait ITimelock<TStorage> {
    // Queue a list of calls to be executed after the delay
    fn queue(ref self: TStorage, calls: Array<Call>) -> felt252;

    fn cancel(ref self: TStorage, id: felt252);
    // Execute a list of calls that have previously been queued
    fn execute(ref self: TStorage, calls: Array<Call>) -> Array<Span<felt252>>;

    // Return the execution window, i.e. the start and end timestamp in which the call can be executed
    fn get_execution_window(self: @TStorage, id: felt252) -> (u64, u64);
    // Get the current owner
    fn get_owner(self: @TStorage) -> ContractAddress;

    // Returns the delay and the window for call execution
    fn get_configuration(self: @TStorage) -> (u64, u64);

    // Transfer ownership, i.e. the address that can queue and cancel calls
    fn transfer(ref self: TStorage, to: ContractAddress);
    // Configure the delay and the window for call execution
    fn configure(ref self: TStorage, delay: u64, window: u64);
}

#[starknet::contract]
mod Timelock {
    use super::{ITimelock, ContractAddress, Call};
    use governance::types::{CallTrait};
    use hash::LegacyHash;
    use array::{ArrayTrait, SpanTrait};
    use starknet::{
        get_caller_address, get_contract_address, SyscallResult, syscalls::call_contract_syscall,
        ContractAddressIntoFelt252, get_block_timestamp
    };
    use result::{ResultTrait};
    use traits::{Into};
    use zeroable::{Zeroable};


    #[storage]
    struct Storage {
        owner: ContractAddress,
        delay: u64,
        window: u64,
        execution_started: LegacyMap<felt252, u64>,
        executed: LegacyMap<felt252, u64>,
        canceled: LegacyMap<felt252, u64>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, delay: u64, window: u64) {
        self.owner.write(owner);
        self.delay.write(delay);
        self.window.write(window);
    }

    // Take a list of calls and convert it to a unique identifier for the execution
    // Two lists of calls will always have the same ID if they are equivalent
    // A list of calls can only be queued and executed once. To make 2 different calls, add an empty call.
    fn to_id(calls: @Array<Call>) -> felt252 {
        let mut state = 0;
        let mut span = calls.span();
        loop {
            match span.pop_front() {
                Option::Some(call) => {
                    state = pedersen(state, call.hash());
                },
                Option::None(_) => {
                    break state;
                }
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
        fn queue(ref self: ContractState, calls: Array<Call>) -> felt252 {
            self.check_owner();

            let id = to_id(@calls);

            assert(self.execution_started.read(id).is_zero(), 'ALREADY_QUEUED');

            self.execution_started.write(id, get_block_timestamp());
            id
        }

        fn cancel(ref self: ContractState, id: felt252) {
            self.check_owner();
            assert(self.execution_started.read(id).is_non_zero(), 'DOES_NOT_EXIST');
            assert(self.executed.read(id).is_zero(), 'ALREADY_EXECUTED');

            self.execution_started.write(id, 0);
        }

        fn execute(ref self: ContractState, calls: Array<Call>) -> Array<Span<felt252>> {
            let id = to_id(@calls);

            assert(self.executed.read(id).is_zero(), 'ALREADY_EXECUTED');

            let (earliest, latest) = self.get_execution_window(id);
            let time_current = get_block_timestamp();

            assert(time_current >= earliest, 'TOO_EARLY');
            assert(time_current < latest, 'TOO_LATE');

            self.executed.write(id, time_current);

            let mut results: Array<Span<felt252>> = ArrayTrait::new();

            let mut call_span = calls.span();
            loop {
                match call_span.pop_front() {
                    Option::Some(call) => {
                        results.append(call.execute());
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            results
        }

        fn get_execution_window(self: @ContractState, id: felt252) -> (u64, u64) {
            let start_time = self.execution_started.read(id);

            // this is how we prevent the 0 timestamp from being considered valid
            assert(start_time != 0, 'DOES_NOT_EXIST');

            let (delay, window) = (self.get_configuration());

            let earliest = start_time + delay;
            let latest = earliest + window;

            (earliest, latest)
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_configuration(self: @ContractState) -> (u64, u64) {
            (self.delay.read(), self.window.read())
        }

        fn transfer(ref self: ContractState, to: ContractAddress) {
            self.check_self_call();

            self.owner.write(to);
        }

        fn configure(ref self: ContractState, delay: u64, window: u64) {
            self.check_self_call();

            self.delay.write(delay);
            self.window.write(window);
        }
    }
}
