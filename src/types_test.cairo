use debug::PrintTrait;
use governance::types::{Call, CallTrait};
use starknet::{contract_address_const};
use array::{Array, ArrayTrait};

#[test]
#[available_gas(300000000)]
fn test_hash_empty() {
    let call = Call {
        address: contract_address_const::<0>(), entry_point_selector: 0, calldata: ArrayTrait::new()
    };
    assert(
        call.hash() == 0x6bf1b215edde951b1b50c19e77f7b362d23c6cb4232ae8b95bc112ff94d3956, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_one() {
    let call = Call {
        address: contract_address_const::<1>(), entry_point_selector: 0, calldata: ArrayTrait::new()
    };
    assert(
        call.hash() == 0x40d1577057b0ad691b66e6d129844046c0f329d8368fbf85a7ef4ff4beffc4c, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_entry_point_one() {
    let call = Call {
        address: contract_address_const::<0>(), entry_point_selector: 1, calldata: ArrayTrait::new()
    };
    assert(
        call.hash() == 0x5f6208726bc717f95f23a8e3632dd5a30f4b61d11db5ea4f4fab24bf931a053, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_data_one() {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(1);
    let call = Call {
        address: contract_address_const::<0>(), entry_point_selector: 0, calldata: calldata
    };

    assert(
        call.hash() == 0x5ad843e478f13c80cd84180f621a6abacca4d9410e6dc5c8b3c1dbf709ff293, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_data_one_two() {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(1);
    calldata.append(2);
    let call = Call {
        address: contract_address_const::<0>(), entry_point_selector: 0, calldata: calldata
    };

    assert(
        call.hash() == 0x34552b59a4ecaac8c01b63dfb0ee31f2e49fb784dc90f58c7475fbcdaf3330b, 'hash'
    );
}
