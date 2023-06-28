#[starknet::interface]
trait IToken<TStorage> {}

#[starknet::contract]
mod Token {
    use super::{IToken};
    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[external(v0)]
    impl TokenImpl of IToken<ContractState> {}
}
