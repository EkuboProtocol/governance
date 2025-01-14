use starknet::storage::MutableVecTrait;
use starknet::storage::{
    Mutable, StorageAsPath, StorageBase, StoragePointerReadAccess, StoragePointerWriteAccess,
};

use starknet::storage::{Vec, VecTrait};
use starknet::storage_access::{StorePacking};
use starknet::{get_block_timestamp};

pub type StakingLog = Vec<StakingLogRecord>;

const TWO_POW_32: u64 = 0x100000000_u64;
const MASK_32_BITS: u128 = 0x100000000_u128 - 1;
const TWO_POW_160: u256 = 0x10000000000000000000000000000000000000000;
pub const MAX_FP: u128 = 0x8000000000000110000000000000000_u128;

#[derive(Drop, Serde, Copy)]
pub(crate) struct StakingLogRecord {
    pub(crate) timestamp: u64,
    // Only 128+32=160 bits are used
    pub(crate) cumulative_total_staked: u256,
    pub(crate) cumulative_seconds_per_total_staked: u256,
}

#[generate_trait]
pub impl StakingLogOperations of LogOperations {
    fn get_total_staked(self: @StorageBase<StakingLog>, timestamp: u64) -> Option<u128> {
        Option::Some(0)
    }

    fn find_in_change_log(
        self: @StorageBase<StakingLog>, timestamp: u64,
    ) -> Option<(StakingLogRecord, u64)> {
        let log = self.as_path();
        if log.len() == 0 {
            return Option::None;
        }
        let mut left = 0;
        let mut right = log.len() - 1;

        // To avoid reading from the storage multiple times.
        let mut result_ptr: Option<(StakingLogRecord, u64)> = Option::None;

        while (left <= right) {
            let center = (right + left) / 2;
            let record_ptr = log.at(center);
            let record = record_ptr.read();

            if record.timestamp <= timestamp {
                result_ptr = Option::Some((record, center));
                left = center + 1;
            } else {
                right = center - 1;
            };
        };

        if let Option::Some((result, idx)) = result_ptr {
            return Option::Some((result, idx));
        }

        return Option::None;
    }

    fn log_change(self: StorageBase<Mutable<StakingLog>>, amount: u128, total_staked: u128) {
        let log = self.as_path();

        let block_timestamp = get_block_timestamp();

        if log.len() == 0 {
            log
                .append()
                .write(
                    StakingLogRecord {
                        timestamp: block_timestamp,
                        cumulative_total_staked: 0_u256,
                        cumulative_seconds_per_total_staked: 0_u64.into(),
                    },
                );

            return;
        }

        let last_record_ptr = log.at(log.len() - 1);

        let mut last_record = last_record_ptr.read();

        let mut record = if last_record.timestamp == block_timestamp {
            // update record
            last_record_ptr
        } else {
            // create new record
            log.append()
        };

        // Might be zero
        let seconds_diff = block_timestamp - last_record.timestamp;

        let total_staked_by_elapsed_seconds = total_staked.into() * seconds_diff.into();

        let staked_seconds_per_total_staked: u256 = if total_staked == 0 {
            0_u64.into()
        } else {
            let res = u256 { low: 0, high: seconds_diff.into() } / total_staked.into();
            assert(res.high < MAX_FP, 'FP_OVERFLOW');
            res
        };

        // Add a new record.
        record
            .write(
                StakingLogRecord {
                    timestamp: block_timestamp,
                    cumulative_total_staked: last_record.cumulative_total_staked
                        + total_staked_by_elapsed_seconds,
                    cumulative_seconds_per_total_staked: last_record
                        .cumulative_seconds_per_total_staked
                        + staked_seconds_per_total_staked,
                },
            );
    }
}

//
// Storage layout for StakingLogRecord
//

pub(crate) impl StakingLogRecordStorePacking of StorePacking<StakingLogRecord, (felt252, felt252)> {
    fn pack(value: StakingLogRecord) -> (felt252, felt252) {
        let packed_ts_cumulative_total_staked: felt252 = pack_u64_u256_tuple(
            value.timestamp, value.cumulative_total_staked,
        );

        let cumulative_seconds_per_total_staked: felt252 = value
            .cumulative_seconds_per_total_staked
            .try_into()
            .unwrap();

        (packed_ts_cumulative_total_staked, cumulative_seconds_per_total_staked)
    }

    fn unpack(value: (felt252, felt252)) -> StakingLogRecord {
        let (packed_ts_cumulative_total_staked, cumulative_seconds_per_total_staked) = value;
        let (timestamp, cumulative_total_staked) = unpack_u64_u256_tuple(
            packed_ts_cumulative_total_staked,
        );

        StakingLogRecord {
            timestamp: timestamp,
            cumulative_total_staked: cumulative_total_staked,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked
                .try_into()
                .unwrap(),
        }
    }
}

pub(crate) fn pack_u64_u256_tuple(val1: u64, val2: u256) -> felt252 {
    let cumulative_total_staked_high_32_bits: u128 = val2.high & MASK_32_BITS;
    u256 {
        high: val1.into() * TWO_POW_32.into() + cumulative_total_staked_high_32_bits.into(),
        low: val2.low,
    }
        .try_into()
        .unwrap()
}

pub(crate) fn unpack_u64_u256_tuple(value: felt252) -> (u64, u256) {
    let packed_ts_total_staked_u256: u256 = value.into();

    let cumulative_total_staked = u256 {
        high: packed_ts_total_staked_u256.high & MASK_32_BITS, low: packed_ts_total_staked_u256.low,
    };

    return (
        (packed_ts_total_staked_u256.high / TWO_POW_32.into()).try_into().unwrap(),
        cumulative_total_staked,
    );
}
