use core::array::{ArrayTrait};
use core::hash::{LegacyHash};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::traits::{TryInto, Into};
use governance::airdrop::{
    IAirdropDispatcher, IAirdropDispatcherTrait, Airdrop, Airdrop::compute_pedersen_root, Claim,
    Airdrop::lt
};
use governance::governance_token::{
    IGovernanceTokenDispatcherTrait, GovernanceToken, IGovernanceTokenDispatcher
};
use governance::governance_token_test::{deploy as deploy_token};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::testing::{pop_log};
use starknet::{
    get_contract_address, syscalls::{deploy_syscall}, ClassHash, contract_address_const,
    ContractAddress
};

fn deploy(token: ContractAddress, root: felt252) -> IAirdropDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(token, root), ref constructor_args);

    let (address, _) = deploy_syscall(
        Airdrop::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_AD_FAILED');
    return IAirdropDispatcher { contract_address: address };
}

#[test]
fn test_selector() {
    assert_eq!(
        selector!("ekubo::governance::airdrop::Claim"),
        0x01782c4dfd9b809591e597c7a90a503c5db310130ec93790567b00d95ac81da0
    );
}

#[test]
fn test_hash() {
    assert_eq!(
        LegacyHash::hash(
            selector!("ekubo::governance::airdrop::Claim"),
            Claim { id: 123, claimee: contract_address_const::<456>(), amount: 789 }
        ),
        0x0760b337026a91a6f2af99a0654f7fdff5d5c8d4e565277e787b99e17b1742a3
    );
}

#[test]
fn test_compute_pedersen_root_example_lt() {
    assert_eq!(
        compute_pedersen_root(1234, array![1235].span()),
        0x24e78083d17aa2e76897f44cfdad51a09276dd00a3468adc7e635d76d432a3b
    );
}

#[test]
fn test_compute_pedersen_root_example_gt() {
    assert_eq!(
        compute_pedersen_root(1234, array![1233].span()),
        0x2488766c14e4bfd8299750797eeb07b7045398df03ea13cf33f0c0c6645d5f9
    );
}

#[test]
fn test_compute_pedersen_root_example_eq() {
    assert_eq!(
        compute_pedersen_root(1234, array![1234].span()),
        0x7a7148565b76ae90576733160aa3194a41ce528ee1434a64a9da50dcbf6d3ca
    );
}

#[test]
fn test_compute_pedersen_root_empty() {
    assert_eq!(compute_pedersen_root(1234, array![].span()), 1234);
}

#[test]
fn test_compute_pedersen_root_recursive() {
    assert_eq!(
        compute_pedersen_root(1234, array![1234, 1234].span()),
        0xc92a4f7aa8979b0202770b378e46de07bebe0836f8ceece5a47ccf3929c6b0
    );
}

#[test]
fn test_claim_single_recipient() {
    let (_, token) = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let proof = ArrayTrait::new();

    airdrop.claim(claim, proof);

    let log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(log.claim, claim);

    pop_log::<GovernanceToken::Transfer>(token.contract_address).unwrap();
    pop_log::<GovernanceToken::Transfer>(token.contract_address).unwrap();
    let log = pop_log::<GovernanceToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(log.from, airdrop.contract_address);
    assert_eq!(log.to, claim.claimee);
    assert_eq!(log.value, claim.amount.into());
}

#[test]
#[available_gas(4000000)]
#[should_panic(expected: ('ALREADY_CLAIMED', 'ENTRYPOINT_FAILED'))]
fn test_double_claim() {
    let (_, token) = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let mut proof = ArrayTrait::new();
    airdrop.claim(claim, proof);
    proof = ArrayTrait::new();
    airdrop.claim(claim, proof);
}

#[test]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_single_entry() {
    let (_, token) = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    airdrop.claim(claim, array![1]);
}

#[test]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_fake_entry() {
    let (_, token) = deploy_token('AIRDROP', 'AD', 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    let proof = ArrayTrait::new();

    airdrop
        .claim(
            Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789 + 1, }, proof
        );
}


#[test]
#[available_gas(30000000)]
fn test_claim_two_claims() {
    let (_, token) = deploy_token('AIRDROP', 'AD', 1234567);

    let claim_a = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };
    let claim_b = Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789, };

    let leaf_a = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim_a);
    let leaf_b = LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim_b);

    let root = if lt(@leaf_a, @leaf_b) {
        core::pedersen::pedersen(leaf_a, leaf_b)
    } else {
        core::pedersen::pedersen(leaf_b, leaf_a)
    };

    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 6789 + 789 + 1);

    airdrop.claim(claim_a, array![leaf_b]);
    assert_eq!(token.balance_of(airdrop.contract_address), (789 + 1));
    assert_eq!(token.balance_of(claim_a.claimee), 6789);

    airdrop.claim(claim_b, array![leaf_a]);
    assert_eq!(token.balance_of(airdrop.contract_address), 1);
    assert_eq!(token.balance_of(claim_b.claimee), 789);
}

#[test]
fn test_claims_from_generated_tree() {
    let claim_0 = Claim {
        id: 0,
        claimee: contract_address_const::<
            1257981684727298919953780547925609938727371268283996697135018561811391002099
        >(),
        amount: 845608158412629999616,
    };

    let claim_1 = Claim {
        id: 1,
        claimee: contract_address_const::<
            2446484730111463702450186103350698828806903266085688038950964576824849476058
        >(),
        amount: 758639984742607224832,
    };

    let (_, token) = deploy_token('AIRDROP', 'AD', claim_0.amount.into() + claim_1.amount.into());

    let root = 2413984000256568988735068618807996871735886303454043475744972321149068137869;
    let airdrop = deploy(token.contract_address, root);

    token.transfer(airdrop.contract_address, claim_0.amount.into() + claim_1.amount.into());

    airdrop
        .claim(
            claim_1,
            array![
                2879705852068751339326970574743249357626496859246711485336045655175496222574,
                2591818886036301641799899841447556295494184204908229358406473782788431853617,
                3433559452610196359109559589502585411529094342760420711041457728474879804685,
                119111708719532621104568211251857481136318454621898627733025381039107349350,
                1550418626007763899979956501892881046988353701960212721885621375458028218469,
                218302537176435686946721821062002958322614343556723420712784506426080342216,
                1753580693918376168416443301945093568141375497403576624304615426611458701443,
                284161108154264923299661757093898525322488115499630822539338320558723810310,
                3378969471732886394431481313236934101872088301949153794471811360320074526103,
                2691963575009292057768595613759919396863463394980592564921927341908988940473,
                22944591007266013337629529054088070826740344136663051917181912077498206093,
                2846046884061389749777735515205600989814522753032574962636562486677935396074
            ]
        );

    let log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(log.claim, claim_1);

    airdrop
        .claim(
            claim_0,
            array![
                390013443931943946052075510188945600544108471539235465760564815348896073043,
                2591818886036301641799899841447556295494184204908229358406473782788431853617,
                3433559452610196359109559589502585411529094342760420711041457728474879804685,
                119111708719532621104568211251857481136318454621898627733025381039107349350,
                1550418626007763899979956501892881046988353701960212721885621375458028218469,
                218302537176435686946721821062002958322614343556723420712784506426080342216,
                1753580693918376168416443301945093568141375497403576624304615426611458701443,
                284161108154264923299661757093898525322488115499630822539338320558723810310,
                3378969471732886394431481313236934101872088301949153794471811360320074526103,
                2691963575009292057768595613759919396863463394980592564921927341908988940473,
                22944591007266013337629529054088070826740344136663051917181912077498206093,
                2846046884061389749777735515205600989814522753032574962636562486677935396074
            ]
        );
}
