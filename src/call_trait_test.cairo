use core::array::{Array, ArrayTrait};
use core::hash::{LegacyHash};
use core::serde::{Serde};
use governance::test::test_token::{deploy as deploy_token};
use governance::call_trait::{CallTrait, HashCall};
use starknet::{contract_address_const, get_contract_address, account::{Call}};

#[test]
fn test_hash_empty() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call),
        0x6bf1b215edde951b1b50c19e77f7b362d23c6cb4232ae8b95bc112ff94d3956
    );
}

#[test]
fn test_hash_empty_different_state() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(1, @call),
        1832368551659298682277041292338758811780503233378895654121359846824467233868
    );
}

#[test]
fn test_hash_address_one() {
    let call = Call { to: contract_address_const::<1>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call),
        0x5f6208726bc717f95f23a8e3632dd5a30f4b61d11db5ea4f4fab24bf931a053
    );
}

#[test]
fn test_hash_address_entry_point_one() {
    let call = Call { to: contract_address_const::<0>(), selector: 1, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call), 0x137c95c76862129847d0f5e3618c7a4c3822ee344f4aa80bcb897cb97d3e16
    );
}

#[test]
fn test_hash_address_data_one() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![1].span() };

    assert_eq!(
        LegacyHash::hash(0, @call),
        0x200a54d7737c13f1013835f88c566515921c2b9c7c7a50cc44ff6f176cf06b2
    );
}

#[test]
fn test_hash_address_data_one_two() {
    let call = Call {
        to: contract_address_const::<0>(), selector: 0, calldata: array![1, 2].span()
    };

    assert_eq!(
        LegacyHash::hash(0, @call),
        0x6f615c05fa309e4041f96f83d47a23acec3d725b47f8c1005f388aa3d26c187
    );
}

#[test]
#[should_panic(expected: ('CONTRACT_NOT_DEPLOYED',))]
fn test_execute_contract_not_deployed() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![].span() };
    call.execute();
}


#[test]
#[should_panic(expected: ('ENTRYPOINT_NOT_FOUND',))]
fn test_execute_invalid_entry_point() {
    let token = deploy_token(get_contract_address(), 1);

    let call = Call { to: token.contract_address, selector: 0, calldata: array![].span() };

    call.execute();
}


#[test]
#[should_panic(expected: ('Failed to deserialize param #1', 'ENTRYPOINT_FAILED'))]
fn test_execute_invalid_call_data_too_short() {
    let token = deploy_token(get_contract_address(), 1);

    let call = Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: array![].span()
    };

    call.execute();
}

#[test]
fn test_execute_valid_call_data() {
    let token = deploy_token(get_contract_address(), 1);

    let mut calldata: Array<felt252> = array![];
    Serde::serialize(@(contract_address_const::<1>(), 1_u256), ref calldata);

    let call = Call {
        to: token.contract_address,
        // transfer
        selector: 0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e,
        calldata: calldata.span()
    };

    call.execute();
}

