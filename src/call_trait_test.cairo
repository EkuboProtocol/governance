use core::hash::{LegacyHash, HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use governance::call_trait::{CallTrait, HashSerializable};
use governance::test::test_token::{deploy as deploy_token};
use starknet::{contract_address_const, get_contract_address, account::{Call}};

#[test]
fn test_hash_empty() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call),
        592531356294457842089938121745653035784273932434733687203842865999223838417
    );
}

#[test]
fn test_hash_empty_different_state() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(1, @call),
        641779498390055840747899186344080567584946769797748441152535133488389427639
    );
}

#[test]
fn test_hash_address_one() {
    let call = Call { to: contract_address_const::<1>(), selector: 0, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call),
        822101510419032526850572827036529302322534847455039029719271666012578939011
    );
}

#[test]
fn test_hash_address_entry_point_one() {
    let call = Call { to: contract_address_const::<0>(), selector: 1, calldata: array![].span() };
    assert_eq!(
        LegacyHash::hash(0, @call),
        2649728997388989667623494598440207295058382579827039351281187174838687580826
    );
}

#[test]
fn test_hash_address_data_one() {
    let call = Call { to: contract_address_const::<0>(), selector: 0, calldata: array![1].span() };

    assert_eq!(
        LegacyHash::hash(0, @call),
        941644435636445739851438544160869526074009333114430642156303468449419287369
    );
}

#[test]
fn test_hash_address_data_one_two() {
    let call = Call {
        to: contract_address_const::<0>(), selector: 0, calldata: array![1, 2].span()
    };

    assert_eq!(
        LegacyHash::hash(0, @call),
        2486526694913415670406871967728275622122901127926391718078378231682443645806
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

#[test]
fn test_hash_no_collision_span_length() {
    let call_a1 = Call {
        to: contract_address_const::<1>(), selector: 2, calldata: array![3, 4].span()
    };
    let call_a2 = Call {
        to: contract_address_const::<5>(), selector: 6, calldata: array![].span()
    };
    let hash_a = PoseidonTrait::new().update_with(@call_a1).update_with(@call_a2).finalize();

    let call_b1 = Call {
        to: contract_address_const::<1>(), selector: 2, calldata: array![].span()
    };
    let call_b2 = Call {
        to: contract_address_const::<3>(), selector: 4, calldata: array![5, 6].span()
    };
    let hash_b = PoseidonTrait::new().update_with(@call_b1).update_with(@call_b2).finalize();

    assert_ne!(hash_a, hash_b);
}

