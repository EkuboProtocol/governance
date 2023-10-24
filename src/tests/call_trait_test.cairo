use debug::PrintTrait;
use governance::call_trait::{CallTrait};
use starknet::{contract_address_const, account::{Call}};
use array::{Array, ArrayTrait};
use governance::tests::governance_token_test::{deploy as deploy_token};
use serde::{Serde};

#[test]
#[available_gas(300000000)]
fn test_hash_empty() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: ArrayTrait::new() };
    assert(
        call.hash() == 0x6bf1b215edde951b1b50c19e77f7b362d23c6cb4232ae8b95bc112ff94d3956, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_one() {
    let call = Call { to: contract_address_const::<1>(), selector: 0, calldata: ArrayTrait::new() };
    assert(
        call.hash() == 0x40d1577057b0ad691b66e6d129844046c0f329d8368fbf85a7ef4ff4beffc4c, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_entry_point_one() {
    let call = Call { to: contract_address_const::<0>(), selector: 1, calldata: ArrayTrait::new() };
    assert(
        call.hash() == 0x5f6208726bc717f95f23a8e3632dd5a30f4b61d11db5ea4f4fab24bf931a053, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
fn test_hash_address_data_one() {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    calldata.append(1);
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: calldata };

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
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: calldata };

    assert(
        call.hash() == 0x34552b59a4ecaac8c01b63dfb0ee31f2e49fb784dc90f58c7475fbcdaf3330b, 'hash'
    );
}

#[test]
#[available_gas(300000000)]
#[should_panic(expected: ('CONTRACT_NOT_DEPLOYED',))]
fn test_execute_contract_not_deployed() {
    let mut calldata: Array<felt252> = ArrayTrait::new();
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: calldata };
    call.execute();
}


#[test]
#[available_gas(300000000)]
#[should_panic(expected: ('ENTRYPOINT_NOT_FOUND',))]
fn test_execute_invalid_entry_point() {
    let (token, _) = deploy_token('TIMELOCK', 'TL', 1);

    let mut calldata: Array<felt252> = ArrayTrait::new();
    let call = Call { to: token.contract_address, selector: 0, calldata: calldata };

    call.execute();
}


#[test]
#[available_gas(300000000)]
#[should_panic(expected: ('Failed to deserialize param #1', 'ENTRYPOINT_FAILED'))]
fn test_execute_invalid_call_data_too_short() {
    let (token, _) = deploy_token('TIMELOCK', 'TL', 1);

    let mut calldata: Array<felt252> = ArrayTrait::new();
    let call = Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata
    };

    call.execute();
}


#[test]
#[available_gas(300000000)]
fn test_execute_valid_call_data() {
    let (token, _) = deploy_token('TIMELOCK', 'TL', 1);

    let mut calldata: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@contract_address_const::<1>(), ref calldata);
    Serde::serialize(@1_u256, ref calldata);

    let call = Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata
    };

    call.execute();
}

