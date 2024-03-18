use governance::utils::u64_tuple_storage::{ThreeU64TupleStorePacking};
use starknet::storage_access::{StorePacking};

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct ExecutionState {
    pub created: u64,
    pub executed: u64,
    pub canceled: u64
}

pub(crate) impl ExecutionStateStorePacking of StorePacking<ExecutionState, felt252> {
    fn pack(value: ExecutionState) -> felt252 {
        ThreeU64TupleStorePacking::pack((value.created, value.executed, value.canceled))
    }

    fn unpack(value: felt252) -> ExecutionState {
        let (created, executed, canceled) = ThreeU64TupleStorePacking::unpack(value);
        ExecutionState { created, executed, canceled }
    }
}
