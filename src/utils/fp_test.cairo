use crate::utils::fp::{UFixedPoint};


#[test]
fn test_add() {
    let f1 : UFixedPoint = 0xFFFFFFFFFFFFFFFF_u64.into();
    let f2 : UFixedPoint = 1_u64.into();
    let res = f1 + f2;
    let z: u256 = res.into();
    assert(z.low == 0, 'low 0');
    assert(z.high == 18446744073709551616, 'high 18446744073709551616');
}

#[test]
fn test_mul() {
    let f1 : UFixedPoint = 7_u64.into();
    let f2 : UFixedPoint = 7_u64.into();
    let res = f1 * f2;
    let z: u256 = res.into();
    assert(z.low == 0, 'low 0');
    assert(z.high == 49, 'high 49');
}

#[test]
fn test_div() {
    let f1 : UFixedPoint = 7_u64.into();
    let f2 : UFixedPoint = 56_u64.into();
    let res: u256 = (f2 / f1).into();
    assert(res.high == 8, 'high 8');
    assert(res.low == 0, 'low 0');
}

#[test]
fn test_comlex() {
    let f2 : UFixedPoint = 2_u64.into();
    let f05: UFixedPoint = 1_u64.into() / f2;
    let uf05: u256 = f05.into();
    let f7 : UFixedPoint = 7_u64.into();
    let f175 : UFixedPoint = 17_u64.into() + f05;
    let res: u256 = (f175 / f7).into();
    assert(res.high == 2, 'high 2');
    assert(res.low == uf05.low, 'low 0.5');
}

// TODO(baitcode): more tests needed