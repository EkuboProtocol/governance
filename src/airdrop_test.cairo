use governance::airdrop::Airdrop::ClaimToLeafTrait;
use governance::token::ITokenDispatcherTrait;
use array::{ArrayTrait};
use debug::PrintTrait;
use governance::airdrop::{
    IAirdropDispatcher, IAirdropDispatcherTrait, Airdrop, Airdrop::compute_pedersen_root, Claim,
    Airdrop::ClaimToLeaf, Airdrop::felt252_lt, IERC20Dispatcher, IERC20DispatcherTrait
};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress
};
use governance::token::{Token, ITokenDispatcher};
use governance::token_test::{deploy as deploy_token};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto, Into};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy(token: IERC20Dispatcher, root: felt252) -> IAirdropDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@token, ref constructor_args);
    Serde::serialize(@root, ref constructor_args);

    let (address, _) = deploy_syscall(
        Airdrop::TEST_CLASS_HASH.try_into().unwrap(), 2, constructor_args.span(), true
    )
        .expect('DEPLOY_AD_FAILED');
    return IAirdropDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_compute_pedersen_root_example_lt() {
    let mut arr = ArrayTrait::new();
    arr.append(1235);
    assert(
        compute_pedersen_root(
            1234, arr.span()
        ) == 0x24e78083d17aa2e76897f44cfdad51a09276dd00a3468adc7e635d76d432a3b,
        'example'
    );
}

#[test]
#[available_gas(3000000)]
fn test_compute_pedersen_root_example_gt() {
    let mut arr = ArrayTrait::new();
    arr.append(1233);
    assert(
        compute_pedersen_root(
            1234, arr.span()
        ) == 0x2488766c14e4bfd8299750797eeb07b7045398df03ea13cf33f0c0c6645d5f9,
        'example'
    );
}

#[test]
#[available_gas(3000000)]
fn test_compute_pedersen_root_example_eq() {
    let mut arr = ArrayTrait::new();
    arr.append(1234);
    assert(
        compute_pedersen_root(
            1234, arr.span()
        ) == 0x7a7148565b76ae90576733160aa3194a41ce528ee1434a64a9da50dcbf6d3ca,
        'example'
    );
}

#[test]
#[available_gas(3000000)]
fn test_compute_pedersen_root_empty() {
    let mut arr = ArrayTrait::new();
    assert(compute_pedersen_root(1234, arr.span()) == 1234, 'example');
}

#[test]
#[available_gas(3000000)]
fn test_compute_pedersen_root_recursive() {
    let mut arr = ArrayTrait::new();
    arr.append(1234);
    arr.append(1234);
    assert(
        compute_pedersen_root(
            1234, arr.span()
        ) == 0xc92a4f7aa8979b0202770b378e46de07bebe0836f8ceece5a47ccf3929c6b0,
        'example'
    );
}

#[test]
#[available_gas(3000000)]
fn test_claim_single_recipient() {
    let token = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { claimee: contract_address_const::<2345>(), amount: 6789,  };

    let leaf = claim.to_leaf();

    let airdrop = deploy(IERC20Dispatcher { contract_address: token.contract_address }, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let proof = ArrayTrait::new();

    airdrop.claim(claim, proof);
}


#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('ALREADY_CLAIMED', 'ENTRYPOINT_FAILED'))]
fn test_double_claim() {
    let token = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { claimee: contract_address_const::<2345>(), amount: 6789,  };

    let leaf = claim.to_leaf();

    let airdrop = deploy(IERC20Dispatcher { contract_address: token.contract_address }, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let mut proof = ArrayTrait::new();
    airdrop.claim(claim, proof);
    proof = ArrayTrait::new();
    airdrop.claim(claim, proof);
}


#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_single_entry() {
    let token = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { claimee: contract_address_const::<2345>(), amount: 6789,  };

    let leaf = claim.to_leaf();

    let airdrop = deploy(IERC20Dispatcher { contract_address: token.contract_address }, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let mut proof = ArrayTrait::new();
    proof.append(1);

    airdrop.claim(claim, proof);
}

#[test]
#[available_gas(3000000)]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_fake_entry() {
    let token = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { claimee: contract_address_const::<2345>(), amount: 6789,  };

    let leaf = claim.to_leaf();

    let airdrop = deploy(IERC20Dispatcher { contract_address: token.contract_address }, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let proof = ArrayTrait::new();

    airdrop.claim(Claim { claimee: contract_address_const::<2345>(), amount: 6789 + 1,  }, proof);
}


#[test]
#[available_gas(3000000)]
fn test_claim_two_claims() {
    let token = deploy_token('AIRDROP', 'AD', 1234567);

    let claim_a = Claim { claimee: contract_address_const::<2345>(), amount: 6789,  };
    let claim_b = Claim { claimee: contract_address_const::<3456>(), amount: 789,  };

    let leaf_a = claim_a.to_leaf();
    let leaf_b = claim_b.to_leaf();

    let root = if felt252_lt(@leaf_a, @leaf_b) {
        pedersen(leaf_a, leaf_b)
    } else {
        pedersen(leaf_b, leaf_a)
    };

    let airdrop = deploy(IERC20Dispatcher { contract_address: token.contract_address }, root);
    token.transfer(airdrop.contract_address, 6789 + 789 + 1);

    let mut proof_a = ArrayTrait::new();
    proof_a.append(leaf_b);
    airdrop.claim(claim_a, proof_a);
    assert(token.balance_of(airdrop.contract_address) == (789 + 1), 'claim a taken');
    assert(token.balance_of(claim_a.claimee) == 6789, 'received');

    let mut proof_b = ArrayTrait::new();
    proof_b.append(leaf_a);
    airdrop.claim(claim_b, proof_b);
    assert(token.balance_of(airdrop.contract_address) == 1, 'claim b taken');
    assert(token.balance_of(claim_b.claimee) == 789, 'received');
}
