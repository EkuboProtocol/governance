use core::traits::TryInto;
use starknet::ContractAddress;

#[starknet::interface]
trait IToken<TStorage> {
    fn name(self: @TStorage) -> felt252;
    fn symbol(self: @TStorage) -> felt252;
    fn decimals(self: @TStorage) -> u8;
    fn total_supply(self: @TStorage) -> u256;
    fn balance_of(self: @TStorage, account: ContractAddress) -> u256;
    fn allowance(self: @TStorage, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TStorage, spender: ContractAddress, amount: u256) -> bool;
    fn increase_allowance(ref self: TStorage, spender: ContractAddress, added_value: u256) -> bool;
    fn decrease_allowance(
        ref self: TStorage, spender: ContractAddress, subtracted_value: u256
    ) -> bool;
}

#[starknet::contract]
mod Token {
    use super::{IToken, ContractAddress};
    use traits::{Into, TryInto};
    use option::{OptionTrait};
    use starknet::{get_caller_address};

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        total_supply: u128,
        balances: LegacyMap<ContractAddress, u128>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u128>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, symbol: felt252, total_supply: u128) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.total_supply.write(total_supply);
        self.balances.write(get_caller_address(), total_supply);
    }

    #[derive(starknet::Event, Drop)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        value: u256,
    }

    #[derive(starknet::Event, Drop)]
    struct Approval {
        owner: ContractAddress,
        spender: ContractAddress,
        value: u256
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
    }

    #[external(v0)]
    impl TokenImpl of IToken<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }
        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }
        fn decimals(self: @ContractState) -> u8 {
            18_u8
        }
        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read().into()
        }
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account).into()
        }
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender)).into()
        }
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.transfer_from(get_caller_address(), recipient, amount)
        }
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let amount_small: u128 = amount.try_into().expect('TRANSFER_AMOUNT_OVERFLOW');

            let caller = get_caller_address();
            if (sender != caller) {
                let allowance = self.allowances.read((sender, caller));

                assert(allowance >= amount_small, 'TRANSFER_FROM_ALLOWANCE');
                self.allowances.write((sender, caller), allowance - amount_small);
            }

            let sender_balance = self.balances.read(sender);
            assert(amount_small <= sender_balance, 'TRANSFER_INSUFFICIENT_BALANCE');
            self.balances.write(sender, sender_balance - amount_small);
            self.balances.write(recipient, self.balances.read(recipient) + amount_small);

            self.emit(Event::Transfer(Transfer { from: sender, to: recipient, value: amount }));
            true
        }
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();
            self
                .allowances
                .write((owner, spender), amount.try_into().expect('APPROVE_AMOUNT_OVERFLOW'));
            self.emit(Event::Approval(Approval { owner, spender, value: amount }));
            true
        }
        fn increase_allowance(
            ref self: ContractState, spender: ContractAddress, added_value: u256
        ) -> bool {
            self.approve(spender, self.allowance(get_caller_address(), spender) + added_value)
        }
        fn decrease_allowance(
            ref self: ContractState, spender: ContractAddress, subtracted_value: u256
        ) -> bool {
            self.approve(spender, self.allowance(get_caller_address(), spender) - subtracted_value)
        }
    }
}
