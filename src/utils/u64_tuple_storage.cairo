use core::integer::{u128_safe_divmod};
use starknet::storage_access::{StorePacking};

const TWO_POW_64: u128 = 0x10000000000000000;

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
