use starknet::{ContractAddress};

#[starknet::interface]
pub(crate) trait IERC20<TStorage> {
    fn balanceOf(self: @TStorage, account: ContractAddress) -> u256;
    fn allowance(self: @TStorage, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256) -> bool;
    fn transferFrom(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TStorage, spender: ContractAddress, amount: u256) -> bool;
}
