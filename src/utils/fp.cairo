use starknet::storage_access::{StorePacking};
use core::num::traits::{WideMul, Zero};
use core::integer::{u512, u512_safe_div_rem_by_u256 };

pub const EPSILON: u256 = 0x10_u256;

// 128.128
#[derive(Drop, Copy, Serde)]
pub struct UFixedPoint { 
    pub(crate) value: u256
}

pub impl UFixedPointStorePacking of StorePacking<UFixedPoint, felt252> {
    fn pack(value: UFixedPoint) -> felt252 {
        value.try_into().unwrap()
    }

    fn unpack(value: felt252) -> UFixedPoint {
        value.into()
    }
}

pub impl UFixedPointPartialEq of PartialEq<UFixedPoint> {
    fn eq(lhs: @UFixedPoint, rhs: @UFixedPoint) -> bool {
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

pub impl UFixedPointZero of Zero<UFixedPoint> {
    fn zero() -> UFixedPoint {
        UFixedPoint { 
            value: u256 {
                low: 0,
                high: 0,
            }
        }
    }

    fn is_zero(self: @UFixedPoint) -> bool {
        self.value.is_zero()
    }

    fn is_non_zero(self: @UFixedPoint) -> bool { !self.is_zero() }
}

pub(crate) impl U256IntoUFixedPoint of Into<u256, UFixedPoint> {
    fn into(self: u256) -> UFixedPoint { UFixedPoint { value: self } }
}

pub(crate) impl UFixedPointIntoU256 of Into<UFixedPoint, u256> {
    fn into(self: UFixedPoint) -> u256 { self.value }
}

pub(crate) impl Felt252IntoUFixedPoint of Into<felt252, UFixedPoint> {
    fn into(self: felt252) -> UFixedPoint { 
        let medium: u256 = self.into();
        medium.into()
    }
}

#[generate_trait]
pub impl UFixedPointImpl of UFixedPointTrait {
    fn get_integer(self: UFixedPoint) -> u128 { self.value.high }
    fn get_fractional(self: UFixedPoint) -> u128 { self.value.low }
}

#[generate_trait]
pub impl UFixedPointShiftImpl of BitShiftImpl {
        
    fn bitshift_128_up(self: UFixedPoint) -> UFixedPoint {
        UFixedPoint { 
            value: u256 {
                low: 0,                
                high: self.value.low, 
            }
        } 
    }

    fn bitshift_128_down(self: UFixedPoint) -> UFixedPoint {
        UFixedPoint { 
            value: u256 {
                low: self.value.high, 
                high: 0, 
            }
        } 
    }
}

pub(crate) impl FixedPointIntoFelt252 of TryInto<UFixedPoint, felt252> {
    fn try_into(self: UFixedPoint) -> Option<felt252> { 
        self.value.try_into()
    }
}

pub impl UFpImplAdd of Add<UFixedPoint> {
    fn add(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        // TODO: overflow checking
        UFixedPoint {
            value: rhs.value + lhs.value
        }
    }
}

pub impl UFpImplSub of Sub<UFixedPoint> {
    fn sub(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        // TODO: underflow checking
        UFixedPoint {
            value: rhs.value - lhs.value
        }
    }
}

pub impl UFpImplMul of Mul<UFixedPoint> {
    fn mul(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {        
        let res: u512 = lhs.value.wide_mul(rhs.value);
        
        UFixedPoint { 
            // res << 128
            value: u256 {
                low: res.limb1,
                high: res.limb2,
            }
        }
    }
}

pub impl UFpImplDiv of Div<UFixedPoint> {
    fn div(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {        
        let left: u512 = u512 {
            limb0: 0,
            limb1: 0,
            limb2: lhs.value.low,
            limb3: lhs.value.high,
        };
        
        assert(rhs.value != 0, 'DIVISION_BY_ZERO');
        
        let (result, _) = u512_safe_div_rem_by_u256(
            left,
            rhs.value.try_into().unwrap(),
        );

        UFixedPoint { 
            value: u256 {
                low: result.limb2,
                high: result.limb3,
            }
        }
    }
}

pub fn div_u64_by_u128(lhs: u64, rhs: u128) -> UFixedPoint {
    // lhs >> 128
    let left: u256 = u256 {
        low: 0,
        high: lhs.into(),
    };

    UFixedPoint {
        value: left / rhs.into()
    }
}

//
//  TODO: Not sure if that is needed. Tests use it.
//

pub(crate) impl U64IntoUFixedPoint of Into<u64, UFixedPoint> {
    fn into(self: u64) -> UFixedPoint { 
        UFixedPoint { 
            value: u256 {
                low: 0,            // fractional 
                high: self.into(), // integer
            }
        } 
    }
}

pub(crate) impl U128IntoUFixedPoint of Into<u128, UFixedPoint> {
    fn into(self: u128) -> UFixedPoint { 
        UFixedPoint { 
            value: u256 {
                low: 0,     // fractional 
                high: self, // integer
            }
        } 
    }
}