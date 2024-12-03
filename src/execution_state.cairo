use starknet::storage_access::{StorePacking};

const TWO_POW_64: u128 = 0x10000000000000000;
const TWO_POW_64_DIVISOR: NonZero<u128> = 0x10000000000000000;

impl TwoU64TupleStorePacking of StorePacking<(u64, u64), u128> {
    fn pack(value: (u64, u64)) -> u128 {
        let (a, b) = value;
        a.into() + (b.into() * TWO_POW_64)
    }

    fn unpack(value: u128) -> (u64, u64) {
        let (q, r) = DivRem::div_rem(value, TWO_POW_64_DIVISOR);
        (r.try_into().unwrap(), q.try_into().unwrap())
    }
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct ExecutionState {
    pub created: u64,
    pub executed: u64,
    pub canceled: u64,
}

impl ExecutionStateStorePacking of StorePacking<ExecutionState, felt252> {
    fn pack(value: ExecutionState) -> felt252 {
        u256 {
            low: TwoU64TupleStorePacking::pack((value.created, value.executed)),
            high: value.canceled.into(),
        }
            .try_into()
            .unwrap()
    }

    fn unpack(value: felt252) -> ExecutionState {
        let u256_value: u256 = value.into();
        let (created, executed) = TwoU64TupleStorePacking::unpack(u256_value.low);
        ExecutionState { created, executed, canceled: u256_value.high.try_into().unwrap() }
    }
}
