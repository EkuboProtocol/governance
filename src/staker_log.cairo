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
    SubPointers, SubPointersMut, 
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
            
            if record.timestamp.read() <= timestamp {
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
        let first: felt252 = u256 {
            high: value.timestamp.into(),
            low: value.total_staked,
        }.try_into().unwrap();
        
        let second: felt252 = value.cumulative_seconds_per_total_staked
            .try_into()
            .unwrap();
        
        (first, second)
    }

    fn unpack(value: (felt252, felt252)) -> StakingLogRecord {
        let (packed_ts_total_staked, cumulative_seconds_per_total_staked) = value;
        let medium: u256 = packed_ts_total_staked.into();
        StakingLogRecord {
            timestamp: medium.high.try_into().unwrap(),
            total_staked: medium.low,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked.try_into().unwrap(),
        }
    }
}


#[derive(Drop, Copy)]
pub(crate) struct StakingLogRecordSubPointers {
    pub(crate) timestamp: StoragePointer<u64>,
    pub(crate) total_staked: StoragePointer<u128>,
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<UFixedPoint124x128>,
}

pub(crate) impl StakingLogRecordSubPointersImpl of SubPointers<StakingLogRecord> {

    type SubPointersType = StakingLogRecordSubPointers;
    
    fn sub_pointers(self: StoragePointer<StakingLogRecord>) -> StakingLogRecordSubPointers {
        let base_address = self.__storage_pointer_address__;

        let mut current_offset = self.__storage_pointer_offset__;
        let __packed_low_128__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset,
        };

        let __packed_high_124__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset + Store::<u128>::size(),
        };

        current_offset = current_offset + Store::<felt252>::size();
        let __packed_felt2__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset,
        };

        StakingLogRecordSubPointers {
            timestamp: __packed_high_124__,
            total_staked: __packed_low_128__,
            cumulative_seconds_per_total_staked: __packed_felt2__,
        }
    }
}

#[derive(Drop, Copy)]
pub(crate) struct StakingLogRecordSubPointersMut {
    pub(crate) timestamp: StoragePointer<Mutable<u64>>,
    pub(crate) total_staked: StoragePointer<Mutable<u128>>,
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<Mutable<UFixedPoint124x128>>,
}

pub(crate) impl StakingLogRecordSubPointersMutImpl of SubPointersMut<StakingLogRecord> {
    
    type SubPointersType = StakingLogRecordSubPointersMut;

    fn sub_pointers_mut(
        self: StoragePointer<Mutable<StakingLogRecord>>,
    ) -> StakingLogRecordSubPointersMut {
        let base_address = self.__storage_pointer_address__;

        let mut current_offset = self.__storage_pointer_offset__;
        let __packed_low_128__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset,
        };

        let __packed_high_124__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset + Store::<u128>::size(),
        };

        current_offset = current_offset + Store::<felt252>::size();
        let __packed_felt2__ = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: current_offset,
        };

        StakingLogRecordSubPointersMut {
            timestamp: __packed_high_124__,
            total_staked: __packed_low_128__,
            cumulative_seconds_per_total_staked: __packed_felt2__,
        }
    }
}
