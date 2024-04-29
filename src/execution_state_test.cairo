use governance::utils::u64_tuple_storage::{ThreeU64TupleStorePacking, TwoU64TupleStorePacking};
[use governance::utils::u64_tuple_storage_test::{assert_pack_unpack};
use starknet::storage_access::{StorePacking};

#[test]
fn test_three_tuple_storage_forward_back() {
    assert_pack_unpack(ExecutionState { created: 123, executed: 234, canceled: 345 });
    assert_pack_unpack(ExecutionState { created: 0, executed: 0, canceled: 0 });

    assert_pack_unpack(
        ExecutionState {
            created: 0xffffffffffffffff, executed: 0xffffffffffffffff, canceled: 0xffffffffffffffff
        }
    );

    assert_pack_unpack(
        ExecutionState { created: 0xffffffffffffffff, executed: 0xffffffffffffffff, canceled: 0 }
    );
    assert_pack_unpack(ExecutionState { created: 0xffffffffffffffff, executed: 0, canceled: 0 });

    assert_pack_unpack(
        ExecutionState { created: 0xffffffffffffffff, executed: 0, canceled: 0xffffffffffffffff }
    );
    assert_pack_unpack(ExecutionState { created: 0, executed: 0, canceled: 0xffffffffffffffff });

    assert_pack_unpack(
        ExecutionState { created: 0, executed: 0xffffffffffffffff, canceled: 0xffffffffffffffff }
    );
}
