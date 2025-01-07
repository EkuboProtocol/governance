use starknet::storage::MutableVecTrait;
use starknet::{Store, get_block_timestamp};
use starknet::storage_access::{StorePacking};

use starknet::storage::{
    Vec, VecTrait
};
use starknet::storage::{
    StoragePointer, 
    StorageBase, Mutable,
    StoragePath, StorageAsPath, 
    SubPointers, 
    StoragePointerReadAccess, StoragePointerWriteAccess
};

use crate::utils::fp::{UFixedPoint124x128, div_u64_by_u128};

pub type StakingLog = Vec<StakingLogRecord>;

#[derive(Drop, Serde)]
pub(crate) struct StakingLogRecord {
    pub(crate) timestamp: u64,
    pub(crate) total_staked: u128,
    pub(crate) cumulative_seconds_per_total_staked: UFixedPoint124x128,
}

#[generate_trait]
pub impl StakingLogOperations of LogOperations {
    fn find_in_change_log(self: @StorageBase<StakingLog>, timestamp: u64) -> Option<StakingLogRecord> {
        let log = self.as_path();

        if log.len() == 0 {
            return Option::None;
        }
        
        let mut left = 0;
        let mut right = log.len() - 1;
        
        // To avoid reading from the storage multiple times.
        let mut result_ptr: Option<StoragePath<StakingLogRecord>> = Option::None;

        while (left <= right) {
            let center = (right + left) / 2;
            let record = log.at(center);
            
            let record_part = record.packed_timestamp_and_total_staked.read();
            if record_part.timestamp <= timestamp {
                result_ptr = Option::Some(record);
                left = center + 1;
            } else {
                right = center - 1;
            };
        };

        if let Option::Some(result) = result_ptr {
            return Option::Some(result.read());
        }
        
        return Option::None;
    }

    // TODO: shall I use ref here?
    fn log_change(self: StorageBase<Mutable<StakingLog>>, amount: u128, is_add: bool) {
        let log = self.as_path();

        if log.len() == 0 {
            // Add the first record. If withdrawal, then it's underflow.
            assert(is_add, 'BAD AMOUNT'); 

            log.append().write(
                StakingLogRecord {
                    timestamp: get_block_timestamp(),
                    total_staked: amount,
                    cumulative_seconds_per_total_staked: 0_u64.into(),
                }
            );
            
            return;
        }

        let last_record_ptr = log.at(log.len() - 1);
            
        let mut last_record = last_record_ptr.read();

        let mut record = if last_record.timestamp == get_block_timestamp() {
            // update record
            last_record_ptr 
        } else {
            // create new record
            log.append()
        };

        // Might be zero
        let seconds_diff = (get_block_timestamp() - last_record.timestamp) / 1000;
            
        let staked_seconds: UFixedPoint124x128 = if last_record.total_staked == 0 {
            0_u64.into()
        } else {
            div_u64_by_u128(seconds_diff, last_record.total_staked)
        };

        let total_staked = if is_add {
            // overflow check
            assert(last_record.total_staked + amount >= last_record.total_staked, 'BAD AMOUNT'); 
            last_record.total_staked + amount
        } else {
            // underflow check
            assert(last_record.total_staked >= amount, 'BAD AMOUNT'); 
            last_record.total_staked - amount
        };

        // Add a new record.
        record.write(
            StakingLogRecord {
                timestamp: get_block_timestamp(),
                total_staked: total_staked,
                cumulative_seconds_per_total_staked: (
                    last_record.cumulative_seconds_per_total_staked + staked_seconds
                ),
            }
        );
    }
}


// 
// Storage layout for StakingLogRecord
// 

pub(crate) impl StakingLogRecordStorePacking of StorePacking<StakingLogRecord, (felt252, felt252)> {
    fn pack(value: StakingLogRecord) -> (felt252, felt252) {
        let packed_ts_total_staked: felt252 = PackedValuesStorePacking::pack((value.timestamp, value.total_staked).into());
        
        let cumulative_seconds_per_total_staked: felt252 = value.cumulative_seconds_per_total_staked
            .try_into()
            .unwrap();
        
        (packed_ts_total_staked, cumulative_seconds_per_total_staked)
    }

    fn unpack(value: (felt252, felt252)) -> StakingLogRecord {
        let (packed_ts_total_staked, cumulative_seconds_per_total_staked) = value;
        let record = PackedValuesStorePacking::unpack(packed_ts_total_staked);
        StakingLogRecord {
            timestamp: record.timestamp,
            total_staked: record.total_staked,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked.try_into().unwrap(),
        }
    }
}

#[derive(Drop, Serde)]
pub(crate) struct PackedPart {
    timestamp: u64,
    total_staked: u128,
}

pub(crate) impl TupleToPackedPart of Into<(u64, u128), PackedPart> {
    fn into(self: (u64, u128)) -> PackedPart { 
        let (timestamp, total_staked) = self;
        PackedPart { timestamp: timestamp, total_staked: total_staked } 
    }
}

pub impl PackedValuesStorePacking of StorePacking<PackedPart, felt252> {
    fn pack(value: PackedPart) -> felt252 {
        u256 {
            high: value.timestamp.into(),
            low: value.total_staked,
        }.try_into().unwrap()
    }

    fn unpack(value: felt252) -> PackedPart {
        let packed_ts_total_staked_u256: u256 = value.into();
        PackedPart {
            timestamp: packed_ts_total_staked_u256.high.try_into().unwrap(), 
            total_staked: packed_ts_total_staked_u256.low
        }
    }
}


//
// Record subpoiters allow to minimase memory read operarions. Thus while doing binary search we ca read only 1 felt252 from memory.
//

#[derive(Drop, Copy)]
pub(crate) struct StakingLogRecordSubPointers {
    pub(crate) packed_timestamp_and_total_staked: StoragePointer<PackedPart>,
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<UFixedPoint124x128>,
}

pub(crate) impl StakingLogRecordSubPointersImpl of SubPointers<StakingLogRecord> {

    type SubPointersType = StakingLogRecordSubPointers;
    
    fn sub_pointers(self: StoragePointer<StakingLogRecord>) -> StakingLogRecordSubPointers {
        let base_address = self.__storage_pointer_address__;

        let total_staked_ptr = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: self.__storage_pointer_offset__,
        };

        let cumulative_seconds_per_total_staked_ptr = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: self.__storage_pointer_offset__ + Store::<felt252>::size(),
        };

        StakingLogRecordSubPointers {
            packed_timestamp_and_total_staked: total_staked_ptr,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked_ptr,
        }
    }
}