#[starknet::interface]
trait ITimelock<TStorage> {}

#[starknet::contract]
mod Timelock {
    use super::{ITimelock};

    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[external(v0)]
    impl TimelockImpl of ITimelock<ContractState> {}
}
