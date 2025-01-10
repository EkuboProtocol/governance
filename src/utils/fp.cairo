use starknet::storage_access::{StorePacking};
use core::num::traits::{WideMul, Zero };
use core::integer::{u512, u512_safe_div_rem_by_u256 };

pub const EPSILON: u256 = 0x10_u256;

// 2^124
pub const MAX_INT: u128 = 0x10000000000000000000000000000000_u128;
pub const HALF: u128    = 0x80000000000000000000000000000000_u128;

pub type UFixedPoint124x128 = u256;

pub mod Errors {
    pub const FP_ADD_OVERFLOW: felt252 = 'FP_ADD_OVERFLOW';
    pub const FP_SUB_OVERFLOW: felt252 = 'FP_SUB_OVERFLOW';
    pub const FP_MUL_OVERFLOW: felt252 = 'FP_MUL_OVERFLOW';
    pub const FP_DIV_OVERFLOW: felt252 = 'FP_DIV_OVERFLOW';
    pub const FP_SUB_UNDERFLOW: felt252 = 'FP_SUB_UNDERFLOW';
    
    pub const DIVISION_BY_ZERO: felt252 = 'DIVISION_BY_ZERO';
}

pub impl UFixedPoint124x128StorePacking of StorePacking<UFixedPoint124x128, felt252> {
    fn pack(value: UFixedPoint124x128) -> felt252 {
        value.try_into().unwrap()
    }

    fn unpack(value: felt252) -> UFixedPoint124x128 {
        value.into()
    }
}

#[generate_trait]
pub impl UFixedPoint124x128Impl of UFixedPointTrait {
    fn get_integer(self: UFixedPoint124x128) -> u128 { self.high }
    fn get_fractional(self: UFixedPoint124x128) -> u128 { self.low }

    fn from_u64(value: u64) -> UFixedPoint124x128 {
        u256 {
            low: 0,
            high: value.into(),
        }
    }

    fn from_u128(value: u128) -> UFixedPoint124x128 {
        u256 {
            low: 0,
            high: value,
        }
    }
    
    fn round(self: UFixedPoint124x128) -> u128 {
        let overflow = if (self.get_fractional() >= HALF) {
            1
        } else {
            0
        };
        self.get_integer() + overflow
    }
}

pub fn div_u64_by_u128(lhs: u64, rhs: u128) -> UFixedPoint124x128 {
    assert(!rhs.is_zero(), Errors::DIVISION_BY_ZERO);

    let res = UFixedPoint124x128Impl::from_u64(lhs) / rhs.into();

    assert(res.high < MAX_INT, Errors::FP_DIV_OVERFLOW);

    res
}

pub fn div_fixed_point_by_fixed_point(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
    let left: u512 = u512 {
        limb0: 0,
        limb1: 0,
        limb2: lhs.low,
        limb3: lhs.high,
    };
    
    assert(rhs != 0, Errors::DIVISION_BY_ZERO);
    
    let (div_res, _) = u512_safe_div_rem_by_u256(
        left,
        rhs.try_into().unwrap(),
    );

    let res = u256 {
        low: div_res.limb1,
        high: div_res.limb2,
    };
    
    assert(res.high < MAX_INT, Errors::FP_DIV_OVERFLOW);

    res
}

pub fn div_u64_by_fixed_point(lhs: u64, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
    assert(!rhs.is_zero(), Errors::DIVISION_BY_ZERO);
    
    div_fixed_point_by_fixed_point(
        UFixedPoint124x128Impl::from_u64(lhs),
        rhs
    )
}

pub fn mul_fixed_point_by_u128(lhs: UFixedPoint124x128, rhs: u128) -> UFixedPoint124x128 {
    let mult_res = lhs.wide_mul(rhs.into());

    let res = UFixedPoint124x128 {
        low: mult_res.limb0,
        high: mult_res.limb1,
    };

    assert(res.high < MAX_INT, Errors::FP_MUL_OVERFLOW);

    res
}

pub fn add_fixed_points(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
    assert(rhs <= rhs + lhs, Errors::FP_ADD_OVERFLOW);
    assert(lhs <= rhs + lhs, Errors::FP_ADD_OVERFLOW);
        
    let res = rhs + lhs;
        
    assert(res.high < MAX_INT, Errors::FP_ADD_OVERFLOW);
        
    res
}

pub fn sub_fixed_points(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
    assert(lhs >= rhs, Errors::FP_SUB_UNDERFLOW);
    // TODO: underflow checking
    let res = lhs - rhs;
    assert(res.high < MAX_INT, Errors::FP_SUB_OVERFLOW);

    res
}
