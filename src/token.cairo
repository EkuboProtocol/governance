use core::traits::TryInto;
use starknet::ContractAddress;

#[starknet::interface]
trait IToken<TStorage> {
    // ERC20 methods
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

    // Delegate tokens from the caller to the given delegate address
    fn delegate(ref self: TStorage, to: ContractAddress);

    // Get how much delegated tokens an address has at a certain timestamp.
    fn get_delegated(self: @TStorage, delegate: ContractAddress, timestamp: u64) -> u128;
    // Get the cumulative delegated amount * seconds for an address at a certain timestamp.
    fn get_delegated_cumulative(self: @TStorage, delegate: ContractAddress, timestamp: u64) -> u256;

    // Get the average amount delegated over the given period of time
    fn get_average_delegated(
        self: @TStorage, delegate: ContractAddress, start: u64, end: u64
    ) -> u128;
}

#[starknet::contract]
mod Token {
    use super::{IToken, ContractAddress};
    use traits::{Into, TryInto};
    use option::{OptionTrait};
    use starknet::{get_caller_address, get_block_timestamp};
    use zeroable::{Zeroable};
    use debug::PrintTrait;

    #[derive(Copy, Drop, storage_access::StorageAccess)]
    struct DelegatedSnapshot {
        timestamp: u64,
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
        delegated_cumulative_num_snapshots: LegacyMap<ContractAddress, u64>,
        delegated_cumulative_snapshot: LegacyMap<(ContractAddress, u64), DelegatedSnapshot>,
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
        fn insert_snapshot(
            ref self: ContractState, address: ContractAddress, timestamp: u64
        ) -> u128 {
            let amount_delegated = self.delegated.read(address);
            let num_snapshots = self.delegated_cumulative_num_snapshots.read(address);

            if num_snapshots.is_non_zero() {
                let last_snapshot = self
                    .delegated_cumulative_snapshot
                    .read((address, num_snapshots - 1));

                // if we haven't just snapshotted this address
                if (last_snapshot.timestamp != timestamp) {
                    self
                        .delegated_cumulative_snapshot
                        .write(
                            (address, num_snapshots),
                            DelegatedSnapshot {
                                timestamp,
                                delegated_cumulative: last_snapshot.delegated_cumulative
                                    + ((timestamp - last_snapshot.timestamp).into()
                                        * amount_delegated.into()),
                            }
                        );
                    self.delegated_cumulative_num_snapshots.write(address, num_snapshots + 1);
                }
            } else {
                // record this timestamp as the first snapshot
                self
                    .delegated_cumulative_snapshot
                    .write(
                        (address, num_snapshots),
                        DelegatedSnapshot { timestamp, delegated_cumulative: 0 }
                    );
                self.delegated_cumulative_num_snapshots.write(address, 1);
            };

            amount_delegated
        }

        fn find_delegated_cumulative(
            self: @ContractState,
            delegate: ContractAddress,
            min_index: u64,
            max_index_exclusive: u64,
            timestamp: u64
        ) -> u256 {
            if (min_index == (max_index_exclusive - 1)) {
                let snapshot = self.delegated_cumulative_snapshot.read((delegate, min_index));
                return if (snapshot.timestamp > timestamp) {
                    0
                } else {
                    let difference = timestamp - snapshot.timestamp;
                    let next = self.delegated_cumulative_snapshot.read((delegate, min_index + 1));
                    let delegated_amount = if (next.timestamp.is_zero()) {
                        self.delegated.read(delegate)
                    } else {
                        ((next.delegated_cumulative - snapshot.delegated_cumulative)
                            / (next.timestamp - snapshot.timestamp).into())
                            .try_into()
                            .unwrap()
                    };

                    snapshot.delegated_cumulative
                        + ((timestamp - snapshot.timestamp).into() * delegated_amount).into()
                };
            }
            let mid = (min_index + max_index_exclusive) / 2;

            let snapshot = self.delegated_cumulative_snapshot.read((delegate, mid));

            if (timestamp == snapshot.timestamp) {
                return snapshot.delegated_cumulative;
            }

            // timestamp we are looking for is before snapshot
            if (timestamp < snapshot.timestamp) {
                self.find_delegated_cumulative(delegate, min_index, mid, timestamp)
            } else {
                self.find_delegated_cumulative(delegate, mid, max_index_exclusive, timestamp)
            }
        }

        fn move_delegates(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u128
        ) {
            if (amount == 0) {
                return ();
            }

            let timestamp = get_block_timestamp();

            if (from.is_non_zero()) {
                self.delegated.write(from, self.insert_snapshot(from, timestamp) - amount);
            }

            if (to.is_non_zero()) {
                self.delegated.write(to, self.insert_snapshot(to, timestamp) + amount);
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
            self.emit(Event::Delegate(Delegate { from: caller, to: to }));
        }

        fn get_delegated(self: @ContractState, delegate: ContractAddress, timestamp: u64) -> u128 {
            (self.get_delegated_cumulative(delegate, timestamp)
                - self.get_delegated_cumulative(delegate, timestamp - 1))
                .try_into()
                .unwrap()
        }

        fn get_delegated_cumulative(
            self: @ContractState, delegate: ContractAddress, timestamp: u64
        ) -> u256 {
            let num_snapshots = self.delegated_cumulative_num_snapshots.read(delegate);
            return if (num_snapshots.is_zero()) {
                0
            } else {
                self.find_delegated_cumulative(delegate, 0, num_snapshots, timestamp)
            };
        }

        fn get_average_delegated(
            self: @ContractState, delegate: ContractAddress, start: u64, end: u64
        ) -> u128 {
            let start_snapshot = self.get_delegated_cumulative(delegate, start);
            let end_snapshot = self.get_delegated_cumulative(delegate, end);

            ((end_snapshot - start_snapshot) / (end - start).into()).try_into().unwrap()
        }
    }
}
