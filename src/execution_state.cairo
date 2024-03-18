use governance::utils::u64_tuple_storage::{TwoU64TupleStorePacking};
use starknet::storage_access::{StorePacking};

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct ExecutionState {
    pub created: u64,
    pub executed: u64,
    pub canceled: u64
}

pub(crate) impl ExecutionStateStorePacking of StorePacking<ExecutionState, felt252> {
    fn pack(value: ExecutionState) -> felt252 {
        u256 {
            low: TwoU64TupleStorePacking::pack((value.created, value.executed)),
            high: value.canceled.into()
        }
            .try_into()
            .unwrap()
    }

    fn unpack(value: felt252) -> ExecutionState {
        let u256_value: u256 = value.into();
        let (created, executed) = TwoU64TupleStorePacking::unpack(u256_value.low);
        ExecutionState { created, executed, canceled: (u256_value.high).try_into().unwrap() }
    }
}
