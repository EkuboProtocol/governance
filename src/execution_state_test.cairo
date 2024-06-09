use governance::execution_state::ExecutionState;
use starknet::storage_access::StorePacking;

pub(crate) fn assert_pack_unpack<
    T, U, +StorePacking<T, U>, +PartialEq<T>, +core::fmt::Debug<T>, +Drop<T>, +Copy<T>
>(
    x: T
) {
    assert_eq!(x, StorePacking::<T, U>::unpack(StorePacking::<T, U>::pack(x)));
}

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
    assert_pack_unpack(ExecutionState { created: 0, executed: 0xffffffffffffffff, canceled: 0 });
}
