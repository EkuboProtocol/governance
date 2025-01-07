use starknet::storage_access::{StorePacking};
use core::num::traits::{WideMul, Zero};
use core::integer::{u512, u512_safe_div_rem_by_u256 };

pub const EPSILON: u256 = 0x10_u256;

// 2^124
pub const MAX_INT: u128 = 0x10000000000000000000000000000000_u128;

// 124.128 (= 252 which 1 felt exactly) 
#[derive(Debug, Drop, Copy, Serde)]
pub struct UFixedPoint124x128 { 
    value: u256
}

pub mod Errors {
    pub const INTEGER_OVERFLOW: felt252 = 'INTEGER_OVERFLOW';
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

pub impl UFixedPoint124x128PartialEq of PartialEq<UFixedPoint124x128> {
    fn eq(lhs: @UFixedPoint124x128, rhs: @UFixedPoint124x128) -> bool {
        let left: u256 = (*lhs).value;
        let right: u256 = (*rhs).value;

        let diff = if left > right {
            left - right 
        } else {
            right - left
        };
        
        diff < EPSILON
    }
}

pub impl UFixedPoint124x128Zero of Zero<UFixedPoint124x128> {
    fn zero() -> UFixedPoint124x128 {
        UFixedPoint124x128 { 
            value: u256 {
                low: 0,
                high: 0,
            }
        }
    }

    fn is_zero(self: @UFixedPoint124x128) -> bool {
        self.value.is_zero()
    }

    fn is_non_zero(self: @UFixedPoint124x128) -> bool { !self.is_zero() }
}

pub(crate) impl U256IntoUFixedPoint of Into<u256, UFixedPoint124x128> {
    fn into(self: u256) -> UFixedPoint124x128 { UFixedPoint124x128 { value: self } }
}

pub(crate) impl UFixedPointIntoU256 of Into<UFixedPoint124x128, u256> {
    fn into(self: UFixedPoint124x128) -> u256 { self.value }
}

pub(crate) impl Felt252IntoUFixedPoint of Into<felt252, UFixedPoint124x128> {
    fn into(self: felt252) -> UFixedPoint124x128 { 
        let medium: u256 = self.into();
        medium.into()
    }
}

#[generate_trait]
pub impl UFixedPoint124x128Impl of UFixedPointTrait {
    fn get_integer(self: UFixedPoint124x128) -> u128 { self.value.high }
    fn get_fractional(self: UFixedPoint124x128) -> u128 { self.value.low }

    fn validate(self: UFixedPoint124x128) { 
        assert(self.value.high < MAX_INT, Errors::INTEGER_OVERFLOW);
    }
}

pub(crate) impl UFixedPoint124x128IntoFelt252 of TryInto<UFixedPoint124x128, felt252> {
    fn try_into(self: UFixedPoint124x128) -> Option<felt252> { 
        self.value.try_into()
    }
}

pub impl UFixedPoint124x128ImplAdd of Add<UFixedPoint124x128> {
    fn add(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
        let res = UFixedPoint124x128 {
            value: rhs.value + lhs.value
        };
        res.validate();
        
        res
    }
}

pub impl UFixedPoint124x128ImplSub of Sub<UFixedPoint124x128> {
    fn sub(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {
        // TODO: underflow checking
        let res = UFixedPoint124x128 {
            value: rhs.value - lhs.value
        };
        res.validate();
        
        res
    }
}

pub impl UFixedPoint124x128ImplMul of Mul<UFixedPoint124x128> {
    fn mul(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {        
        let mult_res: u512 = lhs.value.wide_mul(rhs.value);

        let res = UFixedPoint124x128 { 
            // res << 128
            value: u256 {
                low: mult_res.limb1,
                high: mult_res.limb2,
            }
        };
        res.validate();

        res
    }
}

pub impl UFixedPoint124x128ImplDiv of Div<UFixedPoint124x128> {
    fn div(lhs: UFixedPoint124x128, rhs: UFixedPoint124x128) -> UFixedPoint124x128 {        
        let left: u512 = u512 {
            limb0: 0,
            limb1: 0,
            limb2: lhs.value.low,
            limb3: lhs.value.high,
        };
        
        assert(rhs.value != 0, Errors::DIVISION_BY_ZERO);
        
        let (div_res, _) = u512_safe_div_rem_by_u256(
            left,
            rhs.value.try_into().unwrap(),
        );

        let res = UFixedPoint124x128 { 
            value: u256 {
                low: div_res.limb1,
                high: div_res.limb2,
            }
        };
        
        res.validate();

        res
    }
}

pub fn div_u64_by_u128(lhs: u64, rhs: u128) -> UFixedPoint124x128 {
    assert(!rhs.is_zero(), Errors::DIVISION_BY_ZERO);
    
    // lhs >> 128
    let left: u256 = u256 {
        low: 0,
        high: lhs.into(),
    };

    let res = UFixedPoint124x128 {
        value: left / rhs.into()
    };

    res.validate();

    res
}

//
//  TODO: Not sure if that is needed. Tests use it.
//

pub(crate) impl U64IntoUFixedPoint of Into<u64, UFixedPoint124x128> {
    fn into(self: u64) -> UFixedPoint124x128 { 
        UFixedPoint124x128 { 
            value: u256 {
                low: 0,            // fractional 
                high: self.into(), // integer
            }
        } 
    }
}

pub(crate) impl U128IntoUFixedPoint of Into<u128, UFixedPoint124x128> {
    fn into(self: u128) -> UFixedPoint124x128 { 
        let res = UFixedPoint124x128 { 
            value: u256 {
                low: 0,     // fractional 
                high: self, // integer
            }
        };

        res.validate();

        res
    }
}