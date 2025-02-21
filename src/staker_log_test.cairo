use crate::staker_log::{pack_u64_u256_tuple, unpack_u64_u256_tuple};

const MASK_32_BITS: u128 = 0x100000000_u128 - 1;
const MASK_64_BITS: u128 = 0x10000000000000000_u128 - 1;
const MASK_160_BITS: u256 = 0x10000000000000000000000000000000000000000 - 1;


fn assert_packs_and_unpacks(timestamp: u64, total_staked: u256) {
    let packed: u256 = pack_u64_u256_tuple(timestamp, total_staked).into();

    let first_160_bits: u256 = packed & MASK_160_BITS;

    let shifted_160_bits_right: u128 = packed.high / (MASK_32_BITS + 1);

    let last_64_bits: u64 = (shifted_160_bits_right & MASK_64_BITS).try_into().unwrap();
    assert_eq!(first_160_bits, total_staked);
    assert_eq!(last_64_bits, timestamp);

    let (unpacked_timestamp, unpacked_cumulative_total_staked) = unpack_u64_u256_tuple(
        packed.try_into().unwrap(),
    );
    assert_eq!(unpacked_timestamp, timestamp);
    assert_eq!(unpacked_cumulative_total_staked, total_staked);
}

#[test]
fn test_staking_log_packing() {
    assert_packs_and_unpacks(0_u64, 0_u256);
    assert_packs_and_unpacks(10_u64, 50_u256);
    assert_packs_and_unpacks(
        0xffffffffffffffff_u64, 0xffffffffffffffffffffffffffffffffffffffff_u256,
    )
}
