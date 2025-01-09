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

const TWO_POW_32: u64 = 0x100000000_u64;
const MASK_32_BITS: u128 = 0x100000000_u128 - 1;
const TWO_POW_160: u256 = 0x10000000000000000000000000000000000000000;

#[derive(Drop, Serde, Copy)]
pub(crate) struct StakingLogRecord {
    pub(crate) timestamp: u64,
    
    // Only 128+32=160 bits are used
    // TODO: add validation checks
    pub(crate) cumulative_total_staked: u256,    
    pub(crate) cumulative_seconds_per_total_staked: UFixedPoint124x128,   
}

#[generate_trait]
pub impl StakingLogOperations of LogOperations {

    fn get_total_staked(self: @StorageBase<StakingLog>, timestamp: u64) -> Option<u128> {
        Option::Some(0)
    }

    fn find_in_change_log(self: @StorageBase<StakingLog>, timestamp: u64) -> Option<(StakingLogRecord, u64)> {
        let log = self.as_path();

        if log.len() == 0 {
            return Option::None;
        }
        
        let mut left = 0;
        let mut right = log.len() - 1;
        
        // To avoid reading from the storage multiple times.
        let mut result_ptr: Option<(StoragePath<StakingLogRecord>, u64)> = Option::None;

        while (left <= right) {
            let center = (right + left) / 2;
            let record = log.at(center);
            
            let record_part = record.packed_timestamp_and_cumulative_total_staked.read();
            if record_part.timestamp <= timestamp {
                result_ptr = Option::Some((record, center));
                left = center + 1;
            } else {
                right = center - 1;
            };
        };

        if let Option::Some((result, idx)) = result_ptr {
            return Option::Some((result.read(), idx));
        }
        
        return Option::None;
    }

    fn log_change(self: StorageBase<Mutable<StakingLog>>, amount: u128, total_staked: u128) {
        let log = self.as_path();

        if log.len() == 0 {
            log.append().write(
                StakingLogRecord {
                    timestamp: get_block_timestamp(),
                    cumulative_total_staked: 0_u256,
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
            
        let total_staked_by_elapsed_seconds = total_staked.into() * seconds_diff.into();

        let staked_seconds_per_total_staked: UFixedPoint124x128 = if total_staked == 0 {
            0_u64.into()
        } else {
            div_u64_by_u128(seconds_diff, total_staked)
        };

        // assert(last_record.cumulative_total_staked + total_staked_by_elapsed_seconds < TWO_POW_160, 'TOTAL_STAKED_OVERFLOW');

        // Add a new record.
        record.write(
            StakingLogRecord {
                timestamp: get_block_timestamp(),
                
                cumulative_total_staked: 
                    last_record.cumulative_total_staked + total_staked_by_elapsed_seconds,
                
                cumulative_seconds_per_total_staked: 
                    last_record.cumulative_seconds_per_total_staked + staked_seconds_per_total_staked,
            }
        );
    }
}


// 
// Storage layout for StakingLogRecord
// 

pub(crate) impl StakingLogRecordStorePacking of StorePacking<StakingLogRecord, (felt252, felt252)> {
    fn pack(value: StakingLogRecord) -> (felt252, felt252) {
        let packed_ts_cumulative_total_staked: felt252 = PackedValuesStorePacking::pack((
            value.timestamp, 
            value.cumulative_total_staked
        ).into());
        
        let cumulative_seconds_per_total_staked: felt252 = value.cumulative_seconds_per_total_staked
            .try_into()
            .unwrap();
        
        (packed_ts_cumulative_total_staked, cumulative_seconds_per_total_staked)
    }

    fn unpack(value: (felt252, felt252)) -> StakingLogRecord {
        let (packed_ts_cumulative_total_staked, cumulative_seconds_per_total_staked) = value;
        let record = PackedValuesStorePacking::unpack(packed_ts_cumulative_total_staked);
        StakingLogRecord {
            timestamp: record.timestamp,
            cumulative_total_staked: record.cumulative_total_staked,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked.try_into().unwrap(),
        }
    }
}

#[derive(Drop, Serde)]
pub(crate) struct PackedRecordPart {
    pub(crate) timestamp: u64,
    pub(crate) cumulative_total_staked: u256,
}

pub(crate) impl TupleToPackedPart of Into<(u64, u256), PackedRecordPart> {
    fn into(self: (u64, u256)) -> PackedRecordPart { 
        let (timestamp, cumulative_total_staked) = self;
        PackedRecordPart { 
            timestamp: timestamp, 
            cumulative_total_staked: cumulative_total_staked 
        } 
    }
}

pub impl PackedValuesStorePacking of StorePacking<PackedRecordPart, felt252> {
    // Layout:
    // high = cumulative_total_staked.high 32 bits + timestamp << 32 64 bits
    // low = cumulative_total_staked.low 128 bits

    fn pack(value: PackedRecordPart) -> felt252 {
        let cumulative_total_staked_high_32_bits: u128 = value.cumulative_total_staked.high & MASK_32_BITS;
        u256 {
            high: value.timestamp.into() * TWO_POW_32.into() + cumulative_total_staked_high_32_bits.into(),
            low: value.cumulative_total_staked.low,
        }.try_into().unwrap()
    }

    fn unpack(value: felt252) -> PackedRecordPart {
        let packed_ts_total_staked_u256: u256 = value.into();
        
        let cumulative_total_staked = u256 {
            high: packed_ts_total_staked_u256.high & MASK_32_BITS,
            low: packed_ts_total_staked_u256.low
        };
        
        PackedRecordPart {
            timestamp: (packed_ts_total_staked_u256.high / TWO_POW_32.into()).try_into().unwrap(), 
            cumulative_total_staked: cumulative_total_staked
        }
    }
}

//
// Record subpoiters allow to minimase memory read operarions. Thus while doing binary search we ca read only 1 felt252 from memory.
//

#[derive(Drop, Copy)]
pub(crate) struct StakingLogRecordSubPointers {
    pub(crate) packed_timestamp_and_cumulative_total_staked: StoragePointer<PackedRecordPart>,
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<UFixedPoint124x128>,
}

pub(crate) impl StakingLogRecordSubPointersImpl of SubPointers<StakingLogRecord> {

    type SubPointersType = StakingLogRecordSubPointers;
    
    fn sub_pointers(self: StoragePointer<StakingLogRecord>) -> StakingLogRecordSubPointers {
        let base_address = self.__storage_pointer_address__;

        let packed_timestamp_and_cumulative_total_staked_ptr = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: self.__storage_pointer_offset__,
        };

        let cumulative_seconds_per_total_staked_ptr = StoragePointer {
            __storage_pointer_address__: base_address, 
            __storage_pointer_offset__: self.__storage_pointer_offset__ + Store::<felt252>::size(),
        };

        StakingLogRecordSubPointers {
            packed_timestamp_and_cumulative_total_staked: packed_timestamp_and_cumulative_total_staked_ptr,
            cumulative_seconds_per_total_staked: cumulative_seconds_per_total_staked_ptr,
        }
    }
}
