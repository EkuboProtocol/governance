use governance::utils::u64_tuple_storage::{TwoU64TupleStorePacking};
use starknet::storage_access::{StorePacking};

pub(crate) fn assert_pack_unpack<
    T, U, +StorePacking<T, U>, +PartialEq<T>, +core::fmt::Debug<T>, +Drop<T>, +Copy<T>
>(
    x: T
) {
    assert_eq!(x, StorePacking::<T, U>::unpack(StorePacking::<T, U>::pack(x)));
}

#[test]
fn test_two_tuple_storage_forward_back() {
    assert_pack_unpack((123_u64, 234_u64));
    assert_pack_unpack((0_u64, 0_u64));
    assert_pack_unpack((0xffffffffffffffff_u64, 0xffffffffffffffff_u64));
    assert_pack_unpack((0xffffffffffffffff_u64, 0_u64));
    assert_pack_unpack((0_u64, 0xffffffffffffffff_u64));
}
