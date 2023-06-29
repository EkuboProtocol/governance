use starknet::{ContractAddress};

#[derive(Drop, Serde)]
struct Call {
    callee: ContractAddress,
    data: Array<felt252>,
}

#[starknet::interface]
trait ITimelock<TStorage> {
    fn queue(ref self: TStorage, calls: Array<Call>) -> felt252;
    fn execute(ref self: TStorage, calls: Array<Call>);
    fn cancel(ref self: TStorage, id: felt252);
    fn get_execution_window(self: @TStorage, id: felt252) -> (u64, u64);
    fn get_owner(self: @TStorage) -> ContractAddress;
    fn get_delay(self: @TStorage) -> u64;
    fn get_window(self: @TStorage) -> u64;
}

#[starknet::contract]
mod Timelock {
    use super::{ITimelock, ContractAddress, Call};

    #[storage]
    struct Storage {
        owner: ContractAddress,
        delay: u64,
        window: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, delay: u64, window: u64) {
        self.owner.write(owner);
        self.delay.write(delay);
        self.window.write(window);
    }

    #[external(v0)]
    impl TimelockImpl of ITimelock<ContractState> {
        fn queue(ref self: ContractState, calls: Array<Call>) -> felt252 {
            0
        }
        fn execute(ref self: ContractState, calls: Array<Call>) {}
        fn cancel(ref self: ContractState, id: felt252) {}
        fn get_execution_window(self: @ContractState, id: felt252) -> (u64, u64) {
            (0_u64, 0_u64)
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
        fn get_delay(self: @ContractState) -> u64 {
            self.delay.read()
        }
        fn get_window(self: @ContractState) -> u64 {
            self.window.read()
        }
    }
}
