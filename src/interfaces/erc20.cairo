use starknet::{ContractAddress};

#[starknet::interface]
trait IERC20<TStorage> {
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256);
    fn balance_of(self: @TStorage, account: ContractAddress) -> u256;
}
