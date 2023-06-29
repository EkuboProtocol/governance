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

    fn delegate(ref self: TStorage, to: ContractAddress);

    fn get_delegated(self: @TStorage, delegate: ContractAddress) -> u128;
    fn get_delegated_cumulative(self: @TStorage, delegate: ContractAddress) -> u256;
}

#[starknet::contract]
mod Token {
    use super::{IToken, ContractAddress};
    use traits::{Into, TryInto};
    use option::{OptionTrait};
    use starknet::{get_caller_address, get_block_timestamp};
    use zeroable::{Zeroable};

    #[derive(Copy, Drop, storage_access::StorageAccess)]
    struct DelegatedAccumulator {
        timestamp_last: u64,
        delegated_cumulative: u256,
    }

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        total_supply: u128,
        balances: LegacyMap<ContractAddress, u128>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u128>,
        delegates: LegacyMap<ContractAddress, ContractAddress>,
        delegated: LegacyMap<ContractAddress, u128>,
        delegated_cumulative: LegacyMap<ContractAddress, DelegatedAccumulator>,
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
    struct Delegate {
        from: ContractAddress,
        to: ContractAddress,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        Delegate: Delegate,
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn move_delegates(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u128
        ) {
            if (amount == 0) {
                return ();
            }

            let timestamp = get_block_timestamp();

            if (from.is_non_zero()) {
                self
                    .delegated_cumulative
                    .write(
                        from,
                        DelegatedAccumulator {
                            timestamp_last: timestamp,
                            delegated_cumulative: self.get_delegated_cumulative(from),
                        }
                    );
                self.delegated.write(from, self.delegated.read(from) - amount);
            }

            if (to.is_non_zero()) {
                self
                    .delegated_cumulative
                    .write(
                        to,
                        DelegatedAccumulator {
                            timestamp_last: timestamp,
                            delegated_cumulative: self.get_delegated_cumulative(to),
                        }
                    );
                self.delegated.write(to, self.delegated.read(to) + amount);
            }
        }
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

        fn delegate(ref self: ContractState, to: ContractAddress) {
            let caller = get_caller_address();
            let old = self.delegates.read(caller);

            self.delegates.write(caller, to);
            self.move_delegates(old, to, self.balances.read(caller));
        }

        fn get_delegated(self: @ContractState, delegate: ContractAddress) -> u128 {
            self.delegated.read(delegate)
        }

        fn get_delegated_cumulative(self: @ContractState, delegate: ContractAddress) -> u256 {
            let accumulator = self.delegated_cumulative.read(delegate);
            let timestamp = get_block_timestamp();
            if (timestamp == accumulator.timestamp_last) {
                accumulator.delegated_cumulative
            } else {
                accumulator.delegated_cumulative
                    + ((timestamp - accumulator.timestamp_last).into()
                        * self.delegated.read(delegate).into())
            }
        }
    }
}
