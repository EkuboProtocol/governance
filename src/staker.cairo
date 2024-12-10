use starknet::{ContractAddress};

#[starknet::interface]
pub trait IStaker<TContractState> {
    // Returns the token this staker references.
    fn get_token(self: @TContractState) -> ContractAddress;

    // Returns the amount staked from the staker to the delegate.
    fn get_staked(
        self: @TContractState, staker: ContractAddress, delegate: ContractAddress,
    ) -> u128;

    // Transfers the approved amount of token from the caller into this contract and delegates it to
    // the given address.
    fn stake(ref self: TContractState, delegate: ContractAddress);

    // Transfers the specified amount of token from the caller into this contract and delegates the
    // voting weight to the specified delegate.
    fn stake_amount(ref self: TContractState, delegate: ContractAddress, amount: u128);

    // Unstakes and withdraws all of the tokens delegated by the sender to the delegate from the
    // contract to the given recipient address.
    fn withdraw(ref self: TContractState, delegate: ContractAddress, recipient: ContractAddress);

    // Unstakes and withdraws the specified amount of tokens delegated by the sender to the delegate
    // from the contract to the given recipient address.
    fn withdraw_amount(
        ref self: TContractState,
        delegate: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
    );

    // Gets the currently delegated amount of token. Note this is not flash-loan resistant.
    fn get_delegated(self: @TContractState, delegate: ContractAddress) -> u128;

    // Gets how much delegated tokens an address has at a certain timestamp.
    fn get_delegated_at(self: @TContractState, delegate: ContractAddress, timestamp: u64) -> u128;

    // Gets the cumulative delegated amount * seconds for an address at a certain timestamp.
    fn get_delegated_cumulative(
        self: @TContractState, delegate: ContractAddress, timestamp: u64,
    ) -> u256;

    // Gets the average amount delegated over the given period, where end > start and end <= current
    // time.
    fn get_average_delegated(
        self: @TContractState, delegate: ContractAddress, start: u64, end: u64,
    ) -> u128;

    // Gets the average amount delegated over the last period seconds.
    fn get_average_delegated_over_last(
        self: @TContractState, delegate: ContractAddress, period: u64,
    ) -> u128;

    // Gets the cumulative staked amount * per second staked for the given timestamp and account.
    fn get_staked_seconds(self: @TContractState, for_address: ContractAddress, at_ts: u64) -> u128;
}

#[starknet::contract]
pub mod Staker {
    use starknet::storage::MutableVecTrait;
use core::num::traits::zero::{Zero};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
        Vec, VecTrait,
    };
    use starknet::{
        get_block_timestamp, get_caller_address, get_contract_address,
        storage_access::{StorePacking},
    };
    use super::{ContractAddress, IStaker};


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
                value.into(), TWO_POW_192_DIVISOR,
            );
            DelegatedSnapshot { timestamp: timestamp.low.try_into().unwrap(), delegated_cumulative }
        }
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct StakingLogRecord {
        timestamp: u64,
        total_staked: u128,
        cumulative_staked_per_second: u128
    }

    #[storage]
    struct Storage {
        token: IERC20Dispatcher,
        // owner, delegate => amount
        staked: Map<(ContractAddress, ContractAddress), u128>,
        amount_delegated: Map<ContractAddress, u128>,
        delegated_cumulative_num_snapshots: Map<ContractAddress, u64>,
        delegated_cumulative_snapshot: Map<ContractAddress, Map<u64, DelegatedSnapshot>>,

        staking_log: Map<ContractAddress, Vec<StakingLogRecord>>
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
            ref self: ContractState, address: ContractAddress, timestamp: u64,
        ) -> u128 {
            let amount_delegated = self.amount_delegated.read(address);
            let mut num_snapshots = self.delegated_cumulative_num_snapshots.read(address);

            let delegate_snapshots_entry = self.delegated_cumulative_snapshot.entry(address);
            if num_snapshots.is_non_zero() {
                let last_snapshot = delegate_snapshots_entry.read(num_snapshots - 1);

                // if we haven't just snapshotted this address
                if (last_snapshot.timestamp != timestamp) {
                    delegate_snapshots_entry
                        .write(
                            num_snapshots,
                            DelegatedSnapshot {
                                timestamp,
                                delegated_cumulative: last_snapshot.delegated_cumulative
                                    + ((timestamp - last_snapshot.timestamp).into()
                                        * amount_delegated.into()),
                            },
                        );
                    num_snapshots += 1;
                    self.delegated_cumulative_num_snapshots.write(address, num_snapshots);
                }
            } else {
                // record this timestamp as the first snapshot
                delegate_snapshots_entry
                    .write(num_snapshots, DelegatedSnapshot { timestamp, delegated_cumulative: 0 });
                self.delegated_cumulative_num_snapshots.write(address, 1);
            };

            amount_delegated
        }

        fn find_delegated_cumulative(
            self: @ContractState,
            delegate: ContractAddress,
            min_index: u64,
            max_index_exclusive: u64,
            timestamp: u64,
        ) -> u256 {
            let snapshots_path = self.delegated_cumulative_snapshot.entry(delegate);
            if (min_index == (max_index_exclusive - 1)) {
                let snapshot = snapshots_path.read(min_index);
                return if (snapshot.timestamp > timestamp) {
                    0
                } else {
                    let difference = timestamp - snapshot.timestamp;
                    let next = snapshots_path.read(min_index + 1);
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

            let snapshot = snapshots_path.read(mid);

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

        fn log_change(ref self: ContractState, delegate: ContractAddress, amount: u128, is_add: bool) {
            let from = get_caller_address();
            let log = self.staking_log.entry(from);

            if let Option::Some(last_record_ptr) = log.get(log.len() - 1) {
                let mut last_record = last_record_ptr.read();

                let mut record = if last_record.timestamp == get_block_timestamp() {
                    // update record
                    last_record_ptr 
                } else {
                    // create new record
                    log.append()
                };

                // Might be zero
                let time_diff = get_block_timestamp() - last_record.timestamp;
                    
                let staked_seconds = last_record.total_staked * time_diff.into() / 1000; // staked seconds

                let total_staked = if is_add {
                    // overflow check
                    assert(last_record.total_staked + amount > last_record.total_staked, 'BAD AMOUNT'); 
                    last_record.total_staked + amount
                } else {
                    // underflow check
                    assert(last_record.total_staked > amount, 'BAD AMOUNT'); 
                    last_record.total_staked - amount
                };

                // Add a new record.
                record.write(
                    StakingLogRecord {
                        timestamp: get_block_timestamp(),
                        total_staked: total_staked,
                        cumulative_staked_per_second: last_record.cumulative_staked_per_second + staked_seconds,
                    }
                );
            } else {
                // Add the first record
                if is_add {
                    log.append().write(
                        StakingLogRecord {
                            timestamp: get_block_timestamp(),
                            total_staked: amount,
                            cumulative_staked_per_second: 0,
                        }
                    );
                } else {
                    assert(false, 'IMPOSSIBRU'); // TODO: fix
                }
            }
        }    

        fn find_in_change_log(self: @ContractState, from: ContractAddress, timestamp: u64) -> Option<StakingLogRecord> {
            // Find first log record in an array whos timestamp is less or equal to timestamp.
            // Uses binary search.
            
            // TODO(baitcode): Should probably be an argument. But seems not possible.
            let log = self.staking_log.entry(from);
            
            let mut left = 0;
            let mut right = log.len() - 1;
            
            // To avoid reading from the storage multiple times.
            let mut result_ptr = Option::None;

            while left <= right {
                let center = (right - left) / 2;
                let record = log.at(center);
                
                if record.timestamp.read() <= timestamp {
                    result_ptr = Option::Some(record);
                    left = center + 1;
                } else {
                    right = center - 1;
                }
            };

            if let Option::Some(result) = result_ptr {
                return Option::Some(result.read());
            }
            
            return Option::None;
        }
    }



    #[abi(embed_v0)]
    impl StakerImpl of IStaker<ContractState> {
        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read().contract_address
        }

        fn get_staked(
            self: @ContractState, staker: ContractAddress, delegate: ContractAddress,
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
                        .expect('ALLOWANCE_OVERFLOW'),
                );
        }

        fn stake_amount(ref self: ContractState, delegate: ContractAddress, amount: u128) {
            let from = get_caller_address();
            let token = self.token.read();

            assert(
                token.transferFrom(from, get_contract_address(), amount.into()),
                'TRANSFER_FROM_FAILED',
            );

            let key = (from, delegate);
            self.staked.write((from, delegate), amount + self.staked.read(key));
            self
                .amount_delegated
                .write(delegate, self.insert_snapshot(delegate, get_block_timestamp()) + amount);
            
            self.log_change(delegate, amount, true);
            
            self.emit(Staked { from, delegate, amount });
        }

        fn withdraw(
            ref self: ContractState, delegate: ContractAddress, recipient: ContractAddress,
        ) {
            self
                .withdraw_amount(
                    delegate, recipient, self.staked.read((get_caller_address(), delegate)),
                )
        }

        fn withdraw_amount(
            ref self: ContractState,
            delegate: ContractAddress,
            recipient: ContractAddress,
            amount: u128,
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
            
            self.log_change(delegate, amount, false);
            
            self.emit(Withdrawn { from, delegate, to: recipient, amount });
        }

        fn get_delegated(self: @ContractState, delegate: ContractAddress) -> u128 {
            self.amount_delegated.read(delegate)
        }

        fn get_delegated_at(
            self: @ContractState, delegate: ContractAddress, timestamp: u64,
        ) -> u128 {
            (self.get_delegated_cumulative(delegate, timestamp)
                - self.get_delegated_cumulative(delegate, timestamp - 1))
                .try_into()
                .unwrap()
        }

        fn get_delegated_cumulative(
            self: @ContractState, delegate: ContractAddress, timestamp: u64,
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
                        timestamp: timestamp,
                    )
            };
        }

        fn get_average_delegated(
            self: @ContractState, delegate: ContractAddress, start: u64, end: u64,
        ) -> u128 {
            assert(end > start, 'ORDER');
            assert(end <= get_block_timestamp(), 'FUTURE');

            let start_snapshot = self.get_delegated_cumulative(delegate, start);
            let end_snapshot = self.get_delegated_cumulative(delegate, end);

            ((end_snapshot - start_snapshot) / (end - start).into()).try_into().unwrap()
        }

        fn get_average_delegated_over_last(
            self: @ContractState, delegate: ContractAddress, period: u64,
        ) -> u128 {
            let now = get_block_timestamp();
            self.get_average_delegated(delegate, now - period, now)
        }

        fn get_staked_seconds(
            self: @ContractState, for_address: ContractAddress, at_ts: u64,
        ) -> u128 {
            if let Option::Some(log_record) = self.find_in_change_log(for_address, at_ts) {
                let time_diff = at_ts - log_record.timestamp;
                let staked_seconds = log_record.total_staked * time_diff.into() / 1000; // staked seconds
                return log_record.cumulative_staked_per_second + staked_seconds;
            } else {
                return 0;
            }
        }
    }
}
