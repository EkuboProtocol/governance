use starknet::{ContractAddress, Store};
use starknet::storage_access::{StorePacking};
use starknet::storage::{StoragePointer, SubPointers, SubPointersMut, Mutable};
use crate::utils::fp::{UFixedPoint};


#[derive(Drop, Serde)]
pub(crate) struct StakingLogRecord {
    pub(crate) timestamp: u64,
    pub(crate) total_staked: u128,
    pub(crate) cumulative_seconds_per_total_staked: UFixedPoint,
}

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
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<UFixedPoint>,
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
    pub(crate) cumulative_seconds_per_total_staked: StoragePointer<Mutable<UFixedPoint>>,
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
