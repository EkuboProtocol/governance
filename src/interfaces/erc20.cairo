use starknet::{ContractAddress};

#[starknet::interface]
pub trait IERC20<TStorage> {
    fn name(self: @TStorage) -> felt252;
    fn symbol(self: @TStorage) -> felt252;
    fn decimals(self: @TStorage) -> u8;
    fn total_supply(self: @TStorage) -> u256;
    fn totalSupply(self: @TStorage) -> u256;
    fn balance_of(self: @TStorage, account: ContractAddress) -> u256;
    fn balanceOf(self: @TStorage, account: ContractAddress) -> u256;
    fn allowance(self: @TStorage, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn transferFrom(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TStorage, spender: ContractAddress, amount: u256) -> bool;
}
