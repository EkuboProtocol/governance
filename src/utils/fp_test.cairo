use core::num::traits::WideMul;
use super::fp::UFixedPointTrait;

use crate::utils::fp::{
    UFixedPoint124x128, 
    div_u64_by_u128, mul_fp_by_u128, div_u64_by_fixed_point,
    MAX_INT
};

const SCALE_FACTOR: u256 = 0x100000000000000000000000000000000;


pub(crate) impl U64IntoUFixedPoint of Into<u128, UFixedPoint124x128> {
    fn into(self: u128) -> UFixedPoint124x128 { 
        let medium = u256 {
            low: 0,
            high: self,
        };
        medium.into()
    }
}


#[test]
fn test_add() {
    let f1 : UFixedPoint124x128 = 0xFFFFFFFFFFFFFFFF_u64.into();
    let f2 : UFixedPoint124x128 = 1_u64.into();
    let res = f1 + f2;
    let z: u256 = res.into();
    assert_eq!(z.low, 0);
    assert_eq!(z.high, 18446744073709551616);
}

#[test]
fn test_fp_value_mapping() {
    let f1 : UFixedPoint124x128 = 7_u64.into();
    assert_eq!(f1.get_fractional(), 0x0);
    assert_eq!(f1.get_integer(), 0x7);

    let val: u256 = f1.into();
    assert_eq!(val, 7_u256*0x100000000000000000000000000000000);
}


#[test]
fn test_mul() {
    let f1 = 7_u64;
    let f2 = 7_u64;

    let expected = (7_u256*SCALE_FACTOR).wide_mul(7_u256*SCALE_FACTOR);
    
    assert_eq!(expected.limb0, 0);
    assert_eq!(expected.limb1, 0);
    assert_eq!(expected.limb2, 49);
    assert_eq!(expected.limb3, 0);
    
    let res: u256 = mul_fp_by_u128(f1.into(), f2.try_into().unwrap()).into();
    assert_eq!(res.high, 49);
    assert_eq!(res.low, 0);
}

#[test]
#[should_panic(expected: 'INTEGER_OVERFLOW')]
fn test_multiplication_overflow() {
    let f1 = MAX_INT - 1;
    let f2 = MAX_INT - 1;
    let _ = mul_fp_by_u128(f1.into(), f2.try_into().unwrap());
}

#[test]
fn test_u256_conversion() {
    let f: u256 = 0x0123456789ABCDEFFEDCBA987654321000112233445566778899AABBCCDDEEFF_u256;
    
    assert_eq!(f.low, 0x00112233445566778899AABBCCDDEEFF);
    assert_eq!(f.high, 0x0123456789ABCDEFFEDCBA9876543210);

    let fp: UFixedPoint124x128 = f.into();
    assert_eq!(fp.get_integer(), f.high);
    assert_eq!(fp.get_fractional(), f.low);
}

fn run_division_test(left: u64, right: u128, expected_int: u128, expected_frac: u128) {
    let res = div_u64_by_u128(left, right);
    
    assert_eq!(res.get_integer(), expected_int);
    assert_eq!(res.get_fractional(), expected_frac);
}

fn run_division_and_multiplication_test(numenator: u64, divisor: u128, mult: u128, expected_int: u128, expected_frac: u128) {
    let divided = div_u64_by_u128(numenator, divisor);
    let res = mul_fp_by_u128(divided, mult);

    assert_eq!(res.get_integer(), expected_int);
    assert_eq!(res.get_fractional(), expected_frac);
}


#[test]
fn test_division() {
    run_division_test(1, 1000, 0, 0x4189374bc6a7ef9db22d0e56041893);
    run_division_test(56, 7, 8, 0);
    run_division_test(0, 7, 0, 0);
                                         
    run_division_test(0x6c9444e9af6eb21, 0xd0ba0d5da1c09d9e57d94820ec138cce, 0x0, 0x852bac969a2350b);
    run_division_test(0xdcbfffffa6958e23, 0x4918d4829fcdf183d6d99f0570f1745, 0x0, 0x3051c1a9f372fbfd4a);
    run_division_test(0xd426b156df76a5a0, 0x6a8f314198ecb47d43cd4aa0a9ca43d9, 0x0, 0x1fdacf0b6d911b54a);
    run_division_test(0xab4741c332625aba, 0xb930f984727d03cbefad17a2e094607d, 0x0, 0xecc471b02bb827d2);
    run_division_test(0xf456e2beec7fafa6, 0xc206153d5f83abbc774cf8bea8f0a27e, 0x0, 0x14263442f5d80ef3d);
    run_division_test(0x85bc433c34460024, 0x8a748e982e70d29d3b59fd4736113ceb, 0x0, 0xf745e5b672b00d3a);
    run_division_test(0xb1db6e9041be65b2, 0x9c7a91635d61b2bccf88160a2fd53dee, 0x0, 0x122f9a1641f14e42b);
    run_division_test(0x2180c4fcbc0f47a3, 0xda8f12b54ad0f583da1417295e12b48a, 0x0, 0x273e0c487a908538);
    run_division_test(0x966c069564807e34, 0xbd2087c1a063e4c9514889201f4293db, 0x0, 0xcb9bf9617ac98b00);
    run_division_test(0xb117842a13d72f4, 0x8ba79e67edcfbd2bec7379332208587b, 0x0, 0x144a02a03bcb8771);
    run_division_test(0x1f48f3feddc9b742, 0x2b409d77edb124901b6cca8b496cd3e0, 0x0, 0xb92af636e340d0d6);

    run_division_test(0x51cb6348d4f073eb, 0xae797e7d, 0x7803938f, 0xc7836eec158af9487775eb8656cf38fc);
    run_division_test(0x62337e9d72ddfb51, 0x59214f47, 0x11a0dcac3, 0x1acf56e174d88003af63f46791468df3);
    run_division_test(0xd5ecb2a682ba1fee, 0x865f3300, 0x1978f8bd2, 0x3354716b276ed7e6c759e14d58ab5767);
    run_division_test(0xda53f5e167d39325, 0x491317ba, 0x2fcdca379, 0xcaab30305da3be6620c494367695761e);
    run_division_test(0x22afcdd641467cd1, 0xdedbc9d, 0x27d85372e, 0x76e1c4fe6939db4dcd8b67f2def5c102);
    run_division_test(0x37bc576886b36435, 0x9563dc74, 0x5f82b8e1, 0xc7c4701f73ebf57b4c59d2f357775a0d);
    run_division_test(0x84bd569f3d7ce768, 0x555d2820, 0x18e1384ee, 0x596b1a4ce6995f4a1229e9f185ec0672);
    run_division_test(0x46106cf2302ff8fa, 0xf6d765c9, 0x48a9ec96, 0x44eb3c9b3e7337e3750761dca19c8098);
    run_division_test(0xe4311b247d0fccd4, 0x751c9792, 0x1f2d0b9ef, 0xb5e4969913d37a40ba6cc33b74a5ea6d);
    run_division_test(0x7bc92347ffca33de, 0x73038c20, 0x113864700, 0xa7549c75ef40e011c8ab37b7f05a706d);

    run_division_test(0x72895698b8a67aa2, 0x6b27b2f8336c0bc, 0x11, 0x1a2768bb9a123be83f2c893726d5d4dc);
    run_division_test(0xe43e43db78e75c8c, 0x3bafd02937f52e73, 0x3, 0xd2f2c717d8d53457b6c4d8a0c400ef74);
    run_division_test(0x39a592b65c336682, 0x4067a77d6291d1db, 0x0, 0xe5232e91c70df514ac6a23241bf0e0d7);
    run_division_test(0x13377d1615ab6af, 0x7418529253740f28, 0x0, 0x2a5feadf29edc86e96db0d477e3a85c);
    run_division_test(0x7c688ba1d6c8ca69, 0xf62124b5d737632d, 0x0, 0x8165c4a3a8e578f36fcae7117511f4c3);
    run_division_test(0x2b48a3776a88ed98, 0x5b21e1adfb41d0a, 0x7, 0x996a2c610569e5b72bcb8d97a3a58c09);
    run_division_test(0x1f1b63f5e8fc99b, 0xa1d46df0d2da3b6c, 0x0, 0x31355ba6f51adc401cbe093d9b3a098);
    run_division_test(0xabf999354e11bcbc, 0xcad7c0d69097196b, 0x0, 0xd90aff57100cf3ccf9fe2377d45d866c);
    run_division_test(0xdca981c1e1cb4c1e, 0xf9c9c0425b10334d, 0x0, 0xe226541f530d56041cd7834f878fe4fa);
    run_division_test(0x2c70aa99601005b4, 0xb2df598860e0ece4, 0x0, 0x3f9a241362c5996e29f7867cd85a8403);
}

#[test]
fn test_division_by_fixed_point_and_rounding() {
    let half = div_u64_by_u128(1_u64, 2_u128);
    
    assert_eq!(div_u64_by_fixed_point(0, half).round(), 0_u128);
    assert_eq!(div_u64_by_fixed_point(1, half).round(), 2_u128);
    assert_eq!(div_u64_by_fixed_point(50, half).round(), 100_u128);
    
    let one_over_thousand = div_u64_by_u128(1_u64, 1000_u128);
    assert_eq!(div_u64_by_fixed_point(100, one_over_thousand).round(), 100000_u128);
    assert_eq!(div_u64_by_fixed_point(200, one_over_thousand).round(), 200000_u128);
    assert_eq!(div_u64_by_fixed_point(300, one_over_thousand).round(), 300000_u128);
    assert_eq!(div_u64_by_fixed_point(400, one_over_thousand).round(), 400000_u128);
    assert_eq!(div_u64_by_fixed_point(500, one_over_thousand).round(), 500000_u128);
    assert_eq!(div_u64_by_fixed_point(600, one_over_thousand).round(), 600000_u128);
    assert_eq!(div_u64_by_fixed_point(700, one_over_thousand).round(), 700000_u128);
    assert_eq!(div_u64_by_fixed_point(800, one_over_thousand).round(), 800000_u128);
    assert_eq!(div_u64_by_fixed_point(900, one_over_thousand).round(), 900000_u128);

    let one_over_four = div_u64_by_u128(1_u64, 4_u128);
    assert_eq!(div_u64_by_fixed_point(1, one_over_four).round(), 4_u128);
    assert_eq!(div_u64_by_fixed_point(2, one_over_four).round(), 8_u128);
    assert_eq!(div_u64_by_fixed_point(3, one_over_four).round(), 12_u128);
    assert_eq!(div_u64_by_fixed_point(4, one_over_four).round(), 16_u128);

    let six = div_u64_by_u128(6_u64, 1_u128);

    assert_eq!(div_u64_by_fixed_point(1, six).round(), 0_u128);
    assert_eq!(div_u64_by_fixed_point(2, six).round(), 0_u128);
    assert_eq!(div_u64_by_fixed_point(3, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(4, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(5, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(6, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(7, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(8, six).round(), 1_u128);
    assert_eq!(div_u64_by_fixed_point(9, six).round(), 2_u128);
    assert_eq!(div_u64_by_fixed_point(10, six).round(), 2_u128);
}

#[test]
fn test_substraction() {
    let one_over_four = div_u64_by_u128(1_u64, 4_u128);
    let one_over_two = div_u64_by_u128(1_u64, 2_u128);

    assert_eq!(one_over_two - one_over_four, one_over_four);
}


#[test]
fn test_division_and_multiplication_by() {
    run_division_and_multiplication_test(0x7fe6d7aa683992c1, 0xd59e88c2c2cf8b662b58477379ec3c5, 0x64566fdc35690d86, 0x3, 0xc136a7d74b488c082a89691a34cf83a4);
    run_division_and_multiplication_test(0x49ccea818ca40f32, 0xb1a0b901dfe18783859c30601b5ccd8, 0x7adf8be5f20e22ee, 0x3, 0x30d1670656d38d261dcefab45ae2e238);
    run_division_and_multiplication_test(0x8d7f9fbff6380515, 0xc373107fd425d17ceb8edd19f268fe9, 0x292f63f7f36a4983, 0x1, 0xdd10b15b82683a17543b3adbd9c52cc5);
    run_division_and_multiplication_test(0xc3e18e7febc4e55b, 0xff4f8b2f5f1be3a5d749f67983c2e1f, 0xb6c6724185a770e8, 0x8, 0xc3adba3b09089fac88e8b3d30a8dd7d0);
    run_division_and_multiplication_test(0x85c71ca825ca72c, 0xeeb4af4a991597e3e0d2ec08f7b1a8, 0x674999ae0e694004, 0x3, 0x9e2a7622fec270adc1ca417941e64cf0);
    run_division_and_multiplication_test(0xb7ee4db7793d7767, 0x38c104ee49ba97de1a51f2a0f731348, 0x8769d0fa019d65ab, 0x1b, 0x6da8c217c5d246f3481b53d6ce321bf0);
    run_division_and_multiplication_test(0x33841fabbb0ee95c, 0x2e8ab4d06279d72ccec95511f222293, 0xe8ac73c7c4d19b13, 0x10, 0x18a91a646eace61645b24e9207c37738);
    run_division_and_multiplication_test(0xc107bce26acc446a, 0x8c724e14d0d54f3db76e6003f857fa8, 0x2c3ee7a6ca275beb, 0x3, 0xccfbe15105a920c68e486ad91439ec75);
    run_division_and_multiplication_test(0xa753b4fb1f4f8828, 0x7254ab5927cb62d64986a1ff6240789, 0xa87210053c3749f7, 0xf, 0x686a030bba609986d0bd3707b995ea97);
    run_division_and_multiplication_test(0xdc7a02e89502151c, 0x98072c1c94111cfd1ed52d396b35d1a, 0xd19d22fc5f018bc7, 0x12, 0xffd594dfa4115e06c34d6ca0416012b4);
}

#[test]
#[should_panic(expected: 'DIVISION_BY_ZERO')]
fn test_division_by_zero() {
    run_division_test(56, 0, 0, 0);
}
