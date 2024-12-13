use starknet::storage_access::{StorePacking};
use core::num::traits::{WideMul, Zero};
use core::integer::{u512, u512_safe_div_rem_by_u256};

// 128.128
#[derive(Drop, Copy, PartialEq)]
pub struct UFixedPoint { 
    pub(crate) value: u512
}

pub impl UFixedPointStorePacking of StorePacking<UFixedPoint, u256> {
    fn pack(value: UFixedPoint) -> u256 {
        value.into()
    }

    fn unpack(value: u256) -> UFixedPoint {
        value.into()
    }
}

pub impl UFixedPointZero of Zero<UFixedPoint> {
    fn zero() -> UFixedPoint {
        UFixedPoint { 
            value: u512 {
                limb0: 0,
                limb1: 0,
                limb2: 0,
                limb3: 0,
            }
        }
    }

    fn is_zero(self: @UFixedPoint) -> bool {
        self.value.limb0 == @0 && 
        self.value.limb1 == @0 && 
        self.value.limb2 == @0 && 
        self.value.limb3 == @0
    }

    fn is_non_zero(self: @UFixedPoint) -> bool { !self.is_zero() }
}

impl UFixedPointSerde of core::serde::Serde<UFixedPoint> {
    fn serialize(self: @UFixedPoint, ref output: Array<felt252>) {
        let value: u256 = (*self).try_into().unwrap();
        Serde::serialize(@value, ref output)
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<UFixedPoint> {
        let value: u256 = Serde::deserialize(ref serialized)?;
        Option::Some(value.into())
    }
}

pub(crate) impl U64IntoUFixedPoint of Into<u64, UFixedPoint> {
    fn into(self: u64) -> UFixedPoint { 
        UFixedPoint { 
            value: u512 {
                limb0: 0,           // fractional 
                limb1: self.into(), // integer
                limb2: 0,
                limb3: 0,
            }
        } 
    }
}

pub(crate) impl U128IntoUFixedPoint of Into<u128, UFixedPoint> {
    fn into(self: u128) -> UFixedPoint { 
        UFixedPoint { 
            value: u512 {
                limb0: 0,           // fractional 
                limb1: self.into(), // integer
                limb2: 0,
                limb3: 0,
            }
        } 
    }
}

pub(crate) impl U256IntoUFixedPoint of Into<u256, UFixedPoint> {
    fn into(self: u256) -> UFixedPoint { 
        UFixedPoint { 
            value: u512 {
                limb0: self.low,  // fractional 
                limb1: self.high, // integer
                limb2: 0,
                limb3: 0,
            }
        } 
    }
}

#[generate_trait]
pub impl UFixedPointImpl of UFixedPointTrait {
    fn get_integer(self: UFixedPoint) -> u128 {
        self.value.limb1
    }

    fn get_fractional(self: UFixedPoint) -> u128 {
        self.value.limb0
    }
}

#[generate_trait]
impl UFixedPointShiftImpl of BitShiftImpl {
        
    fn bitshift_128_up(self: UFixedPoint) -> UFixedPoint {
        UFixedPoint { 
            value: u512 {
                limb0: 0,                
                limb1: self.value.limb0, 
                limb2: self.value.limb1,
                limb3: self.value.limb2,
            }
        } 
    }

    fn bitshift_128_down(self: UFixedPoint) -> UFixedPoint {
        UFixedPoint { 
            value: u512 {
                limb0: self.value.limb1, 
                limb1: self.value.limb2, 
                limb2: self.value.limb3,
                limb3: 0,
            }
        } 
    }
}

pub(crate) impl FixedPointIntoU256 of Into<UFixedPoint, u256> {
    fn into(self: UFixedPoint) -> u256 { self.value.try_into().unwrap() }
}

pub impl UFpImplAdd of Add<UFixedPoint> {
    fn add(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        let sum: u256 = rhs.into() + lhs.into();
        UFixedPoint {
            value: u512 {
                limb0: sum.low,
                limb1: sum.high,
                limb2: 0,
                limb3: 0
            }
        }
    }
}

pub impl UFpImplSub of Sub<UFixedPoint> {
    fn sub(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        let sum: u256 = rhs.into() - lhs.into();
        UFixedPoint {
            value: u512 {
                limb0: sum.low,
                limb1: sum.high,
                limb2: 0,
                limb3: 0
            }
        }
    }
}

// 20100
pub impl UFpImplMul of Mul<UFixedPoint> {
    fn mul(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        let left: u256 = lhs.into();
        let right: u256 = rhs.into();
        
        let z = left.wide_mul(right);
        
        UFixedPoint { value: z }.bitshift_128_down()
    }
}

pub impl UFpImplDiv of Div<UFixedPoint> {
    fn div(lhs: UFixedPoint, rhs: UFixedPoint) -> UFixedPoint {
        let rhs: u256 = rhs.into();
        
        let (result, _) = u512_safe_div_rem_by_u256(
            lhs.bitshift_128_up().value,
            rhs.try_into().unwrap(),
        );

        UFixedPoint { value: result }
    }
}