use core::integer::{u128_safe_divmod};
use starknet::storage_access::{StorePacking};

const TWO_POW_64: u128 = 0x10000000000000000;

pub(crate) impl ThreeU64TupleStorePacking of StorePacking<(u64, u64, u64), felt252> {
    fn pack(value: (u64, u64, u64)) -> felt252 {
        let (a, b, c) = value;
        u256 { low: TwoU64TupleStorePacking::pack((a, b)), high: c.into() }.try_into().unwrap()
    }

    fn unpack(value: felt252) -> (u64, u64, u64) {
        let u256_value: u256 = value.into();
        let (a, b) = TwoU64TupleStorePacking::unpack(u256_value.low);
        (a, b, (u256_value.high).try_into().unwrap())
    }
}

pub(crate) impl TwoU64TupleStorePacking of StorePacking<(u64, u64), u128> {
    fn pack(value: (u64, u64)) -> u128 {
        let (a, b) = value;
        a.into() + b.into() * TWO_POW_64
    }

    fn unpack(value: u128) -> (u64, u64) {
        let (q, r) = u128_safe_divmod(value, TWO_POW_64.try_into().unwrap());
        (r.try_into().unwrap(), q.try_into().unwrap())
    }
}
