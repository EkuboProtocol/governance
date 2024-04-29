use starknet::{ContractAddress};

#[starknet::interface]
pub trait IStaker<TContractState> {
    // Returns the token this staker references
    fn get_token(self: @TContractState) -> ContractAddress;

    // Returns the amount staked from the staker to the delegate
    fn get_staked(
        self: @TContractState, staker: ContractAddress, delegate: ContractAddress
    ) -> u128;

    // Transfer the approved amount of token from the caller into this contract and delegates it to the given address
    fn stake(ref self: TContractState, delegate: ContractAddress);

    // Transfer the specified amount of token from the caller into this contract and delegates the voting weight to the specified delegate
    fn stake_amount(ref self: TContractState, delegate: ContractAddress, amount: u128);

    // Unstakes and withdraws all of the tokens delegated by the sender to the delegate from the contract to the given recipient address
    fn withdraw(ref self: TContractState, delegate: ContractAddress, recipient: ContractAddress);

    // Unstakes and withdraws the specified amount of tokens delegated by the sender to the delegate from the contract to the given recipient address
    fn withdraw_amount(
        ref self: TContractState,
        delegate: ContractAddress,
        recipient: ContractAddress,
        amount: u128
    );

    // Get the currently delegated amount of token. Note this is not flash-loan resistant.
    fn get_delegated(self: @TContractState, delegate: ContractAddress) -> u128;

    // Get how much delegated tokens an address has at a certain timestamp.
    fn get_delegated_at(self: @TContractState, delegate: ContractAddress, timestamp: u64) -> u128;

    // Get the cumulative delegated amount * seconds for an address at a certain timestamp.
    fn get_delegated_cumulative(
        self: @TContractState, delegate: ContractAddress, timestamp: u64
    ) -> u256;

    // Get the average amount delegated over the given period, where end > start and end <= current time
    fn get_average_delegated(
        self: @TContractState, delegate: ContractAddress, start: u64, end: u64
    ) -> u128;

    // Get the average amount delegated over the last period seconds
    fn get_average_delegated_over_last(
        self: @TContractState, delegate: ContractAddress, period: u64
    ) -> u128;
}

#[starknet::contract]
pub mod Staker {
    use core::num::traits::zero::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{Into, TryInto};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{
        get_caller_address, get_contract_address, get_block_timestamp,
        storage_access::{StorePacking}
    };
    use super::{IStaker, ContractAddress};

    #[derive(Copy, Drop, PartialEq, Debug)]
    pub struct DelegatedSnapshot {
        pub timestamp: u64,
        pub delegated_cumulative: u256,
    }

    const TWO_POW_64: u128 = 0x10000000000000000;
    const TWO_POW_192: u256 = 0x1000000000000000000000000000000000000000000000000;
    const TWO_POW_192_DIVISOR: NonZero<u256> = 0x1000000000000000000000000000000000000000000000000;

    pub(crate) impl DelegatedSnapshotStorePacking of StorePacking<DelegatedSnapshot, felt252> {
        fn pack(value: DelegatedSnapshot) -> felt252 {
            assert(value.delegated_cumulative < TWO_POW_192, 'MAX_DELEGATED_CUMULATIVE');
            (value.delegated_cumulative
                + u256 { high: value.timestamp.into() * TWO_POW_64, low: 0 })
                .try_into()
                .unwrap()
        }

        fn unpack(value: felt252) -> DelegatedSnapshot {
            let (timestamp, delegated_cumulative) = DivRem::div_rem(
                value.into(), TWO_POW_192_DIVISOR
            );
            DelegatedSnapshot { timestamp: timestamp.low.try_into().unwrap(), delegated_cumulative }
        }
    }

    #[storage]
    struct Storage {
        token: IERC20Dispatcher,
        // owner, delegate => amount
        staked: LegacyMap<(ContractAddress, ContractAddress), u128>,
        amount_delegated: LegacyMap<ContractAddress, u128>,
        delegated_cumulative_num_snapshots: LegacyMap<ContractAddress, u64>,
        delegated_cumulative_snapshot: LegacyMap<(ContractAddress, u64), DelegatedSnapshot>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: IERC20Dispatcher) {
        self.token.write(token);
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Staked {
        pub from: ContractAddress,
        pub amount: u128,
        pub delegate: ContractAddress,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Withdrawn {
        pub from: ContractAddress,
        pub delegate: ContractAddress,
        pub to: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Staked: Staked,
        Withdrawn: Withdrawn,
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn insert_snapshot(
            ref self: ContractState, address: ContractAddress, timestamp: u64
        ) -> u128 {
            let amount_delegated = self.amount_delegated.read(address);
            let mut num_snapshots = self.delegated_cumulative_num_snapshots.read(address);

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
                    num_snapshots += 1;
                    self.delegated_cumulative_num_snapshots.write(address, num_snapshots);
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
                        self.amount_delegated.read(delegate)
                    } else {
                        ((next.delegated_cumulative - snapshot.delegated_cumulative)
                            / (next.timestamp - snapshot.timestamp).into())
                            .try_into()
                            .unwrap()
                    };

                    snapshot.delegated_cumulative + (difference.into() * delegated_amount).into()
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
    }

    #[abi(embed_v0)]
    impl StakerImpl of IStaker<ContractState> {
        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read().contract_address
        }

        fn get_staked(
            self: @ContractState, staker: ContractAddress, delegate: ContractAddress
        ) -> u128 {
            self.staked.read((staker, delegate))
        }

        fn stake(ref self: ContractState, delegate: ContractAddress) {
            self
                .stake_amount(
                    delegate,
                    self
                        .token
                        .read()
                        .allowance(get_caller_address(), get_contract_address())
                        .try_into()
                        .expect('ALLOWANCE_OVERFLOW')
                );
        }

        fn stake_amount(ref self: ContractState, delegate: ContractAddress, amount: u128) {
            let from = get_caller_address();
            let token = self.token.read();

            assert(
                token.transferFrom(from, get_contract_address(), amount.into()),
                'TRANSFER_FROM_FAILED'
            );

            let key = (from, delegate);
            self.staked.write((from, delegate), amount + self.staked.read(key));
            self
                .amount_delegated
                .write(delegate, self.insert_snapshot(delegate, get_block_timestamp()) + amount);
            self.emit(Staked { from, delegate, amount });
        }

        fn withdraw(
            ref self: ContractState, delegate: ContractAddress, recipient: ContractAddress
        ) {
            self
                .withdraw_amount(
                    delegate, recipient, self.staked.read((get_caller_address(), delegate))
                )
        }

        fn withdraw_amount(
            ref self: ContractState,
            delegate: ContractAddress,
            recipient: ContractAddress,
            amount: u128
        ) {
            let from = get_caller_address();
            let key = (from, delegate);
            let staked = self.staked.read(key);
            assert(staked >= amount, 'INSUFFICIENT_AMOUNT_STAKED');
            self.staked.write(key, staked - amount);
            self
                .amount_delegated
                .write(delegate, self.insert_snapshot(delegate, get_block_timestamp()) - amount);
            assert(self.token.read().transfer(recipient, amount.into()), 'TRANSFER_FAILED');
            self.emit(Withdrawn { from, delegate, to: recipient, amount });
        }

        fn get_delegated(self: @ContractState, delegate: ContractAddress) -> u128 {
            self.amount_delegated.read(delegate)
        }

        fn get_delegated_at(
            self: @ContractState, delegate: ContractAddress, timestamp: u64
        ) -> u128 {
            (self.get_delegated_cumulative(delegate, timestamp)
                - self.get_delegated_cumulative(delegate, timestamp - 1))
                .try_into()
                .unwrap()
        }

        fn get_delegated_cumulative(
            self: @ContractState, delegate: ContractAddress, timestamp: u64
        ) -> u256 {
            assert(timestamp <= get_block_timestamp(), 'FUTURE');

            let num_snapshots = self.delegated_cumulative_num_snapshots.read(delegate);
            return if (num_snapshots.is_zero()) {
                0
            } else {
                self
                    .find_delegated_cumulative(
                        delegate: delegate,
                        min_index: 0,
                        max_index_exclusive: num_snapshots,
                        timestamp: timestamp
                    )
            };
        }

        fn get_average_delegated(
            self: @ContractState, delegate: ContractAddress, start: u64, end: u64
        ) -> u128 {
            assert(end > start, 'ORDER');
            assert(end <= get_block_timestamp(), 'FUTURE');

            let start_snapshot = self.get_delegated_cumulative(delegate, start);
            let end_snapshot = self.get_delegated_cumulative(delegate, end);

            ((end_snapshot - start_snapshot) / (end - start).into()).try_into().unwrap()
        }

        fn get_average_delegated_over_last(
            self: @ContractState, delegate: ContractAddress, period: u64
        ) -> u128 {
            let now = get_block_timestamp();
            self.get_average_delegated(delegate, now - period, now)
        }
    }
}
