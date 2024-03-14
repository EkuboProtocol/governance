use core::num::traits::zero::{Zero};
use core::array::{ArrayTrait, SpanTrait};
use core::hash::{LegacyHash};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::traits::{TryInto, Into};
use governance::airdrop::{
    IAirdropDispatcher, IAirdropDispatcherTrait, Airdrop, Config,
    Airdrop::{compute_pedersen_root, hash_function, hash_claim, compute_root_of_group}, Claim
};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::test::test_token::{TestToken};
use starknet::testing::{pop_log};
use starknet::{
    get_contract_address, syscalls::{deploy_syscall}, ClassHash, contract_address_const,
    ContractAddress
};


pub(crate) fn deploy_token(owner: ContractAddress, amount: u128) -> IERC20Dispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(owner, amount), ref constructor_args);

    let (address, _) = deploy_syscall(
        TestToken::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_TOKEN_FAILED');
    IERC20Dispatcher { contract_address: address }
}


fn deploy_with_refundee(
    token: ContractAddress, root: felt252, refundable_timestamp: u64, refund_to: ContractAddress
) -> IAirdropDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(
        @(token, Config { root, refundable_timestamp, refund_to }), ref constructor_args
    );

    let (address, _) = deploy_syscall(
        Airdrop::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_AD_FAILED');
    IAirdropDispatcher { contract_address: address }
}

fn deploy(token: ContractAddress, root: felt252) -> IAirdropDispatcher {
    deploy_with_refundee(token, root, Zero::zero(), Zero::zero())
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
        hash_claim(Claim { id: 123, claimee: contract_address_const::<456>(), amount: 789 }),
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
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);

    assert_eq!(airdrop.claim(claim, array![].span()), true);

    let log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(log.claim, claim);

    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    let log = pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(log.from, airdrop.contract_address);
    assert_eq!(log.to, claim.claimee);
    assert_eq!(log.value, claim.amount.into());
}

#[test]
fn test_claim_128_single_recipient_tree() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);

    assert_eq!(airdrop.claim_128(array![claim].span(), array![].span()), 1);

    let log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(log.claim, claim);

    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    let log = pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(log.from, airdrop.contract_address);
    assert_eq!(log.to, claim.claimee);
    assert_eq!(log.value, claim.amount.into());
}

#[test]
fn test_double_claim() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    assert_eq!(airdrop.claim(claim, array![].span()), true);
    assert_eq!(airdrop.claim(claim, array![].span()), false);
}

#[test]
fn test_double_claim_128_single_recipient_tree() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    assert_eq!(airdrop.claim_128(array![claim].span(), array![].span()), 1);
    assert_eq!(airdrop.claim_128(array![claim].span(), array![].span()), 0);
}

#[test]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_single_entry() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);
    airdrop.claim(claim, array![1].span());
}

#[test]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_invalid_proof_fake_entry() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };

    let leaf = hash_claim(claim);

    let airdrop = deploy(token.contract_address, leaf);

    token.transfer(airdrop.contract_address, 6789);

    airdrop
        .claim(
            Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789 + 1, },
            array![].span()
        );
}

#[test]
#[should_panic(expected: ('NO_CLAIMS',))]
fn test_compute_root_of_group_empty() {
    compute_root_of_group(array![].span());
}

#[test]
fn test_compute_root_of_group() {
    assert_eq!(
        compute_root_of_group(
            array![Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789 }].span()
        ),
        0x0336963eacdeee5da262a870ddfc7f8d12c6162ebdf58a805941c06d3baf8b40
    );
    assert_eq!(
        compute_root_of_group(
            array![
                Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789 },
                Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789 }
            ]
                .span()
        ),
        0x0526f232ab9be3fef7ac6e1f8fd57f45232f9287ce58073c0436b135e1c77ea7
    );
    assert_eq!(
        compute_root_of_group(
            array![
                Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789 },
                Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789 },
                Claim { id: 2, claimee: contract_address_const::<4567>(), amount: 89 }
            ]
                .span()
        ),
        0x06a2f92ce1d9514d0270addf05923a6aeb568ec3fb962a40ddc62c86d0bd3846
    );
}


#[test]
fn test_compute_root_of_group_large() {
    let mut arr: Array<Claim> = array![];

    let mut i: u64 = 64;
    while i < 256 {
        arr
            .append(
                Claim { id: i, claimee: contract_address_const::<2345>(), amount: (i + 1).into() }
            );
        i += 1;
    };

    assert_eq!(
        compute_root_of_group(arr.span()),
        0x0570d1767033fda8e16a754fccc383a47bc79a60d1b97c905b354adda64355d4
    );
}

#[test]
fn test_compute_root_of_group_large_odd() {
    let mut arr: Array<Claim> = array![];

    let mut i: u64 = 64;
    while i < 257 {
        arr
            .append(
                Claim { id: i, claimee: contract_address_const::<2345>(), amount: (i + 1).into() }
            );
        i += 1;
    };

    assert_eq!(
        compute_root_of_group(arr.span()),
        0x360de0739531ee0f159a2d940ff6b83066a4269da0ce1e2ecad27feebf81d4
    );
}


#[test]
fn test_claim_two_claims() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim_a = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };
    let claim_b = Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789, };

    let leaf_a = hash_claim(claim_a);
    let leaf_b = hash_claim(claim_b);

    let root = hash_function(leaf_a, leaf_b);

    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 6789 + 789 + 1);

    airdrop.claim(claim_a, array![leaf_b].span());
    assert_eq!(token.balanceOf(airdrop.contract_address), (789 + 1));
    assert_eq!(token.balanceOf(claim_a.claimee), 6789);

    airdrop.claim(claim_b, array![leaf_a].span());
    assert_eq!(token.balanceOf(airdrop.contract_address), 1);
    assert_eq!(token.balanceOf(claim_b.claimee), 789);
}

#[test]
fn test_claim_two_claims_via_claim_128() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim_a = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };
    let claim_b = Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789, };

    let leaf_a = hash_claim(claim_a);
    let leaf_b = hash_claim(claim_b);

    let root = hash_function(leaf_a, leaf_b);

    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 6789 + 789);

    assert_eq!(airdrop.claim_128(array![claim_a, claim_b].span(), array![].span()), 2);

    let claim_a_log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(claim_a_log.claim, claim_a);
    let claim_b_log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(claim_b_log.claim, claim_b);

    // pops the initial supply transfer from 0 log
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    // pops the transfer from deployer to airdrop
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();

    let transfer_claim_a_log = pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(transfer_claim_a_log.from, airdrop.contract_address);
    assert_eq!(transfer_claim_a_log.to, claim_a.claimee);
    assert_eq!(transfer_claim_a_log.value, claim_a.amount.into());

    let transfer_claim_b_log = pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(transfer_claim_b_log.from, airdrop.contract_address);
    assert_eq!(transfer_claim_b_log.to, claim_b.claimee);
    assert_eq!(transfer_claim_b_log.value, claim_b.amount.into());

    assert_eq!(airdrop.claim_128(array![claim_a, claim_b].span(), array![].span()), 0);
}

#[test]
#[should_panic(expected: ('INVALID_PROOF', 'ENTRYPOINT_FAILED'))]
fn test_claim_three_claims_one_invalid_via_claim_128() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim_a = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };
    let claim_b = Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789, };
    let claim_b_2 = Claim { id: 2, claimee: contract_address_const::<3456>(), amount: 789, };

    let leaf_a = hash_claim(claim_a);
    let leaf_b = hash_claim(claim_b);

    let root = hash_function(leaf_a, leaf_b);

    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 6789 + 789 + 789);

    assert_eq!(airdrop.claim_128(array![claim_a, claim_b, claim_b_2].span(), array![].span()), 3);
}

fn test_claim_is_valid(root: felt252, claim: Claim, proof: Array<felt252>) {
    let pspan = proof.span();
    let token = deploy_token(get_contract_address(), claim.amount);
    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, claim.amount.into());

    assert_eq!(airdrop.claim(claim, pspan), true);
    assert_eq!(airdrop.claim(claim, pspan), false);

    let claim_log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(claim_log.claim, claim);

    // pops the initial supply transfer from 0 log
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    // pops the transfer from deployer to airdrop
    pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    let transfer_log = pop_log::<TestToken::Transfer>(token.contract_address).unwrap();
    assert_eq!(transfer_log.from, airdrop.contract_address);
    assert_eq!(transfer_log.to, claim.claimee);
    assert_eq!(transfer_log.value, claim.amount.into());
}

#[test]
fn test_claim_from_end_of_tree() {
    test_claim_is_valid(
        root: 2413984000256568988735068618807996871735886303454043475744972321149068137869,
        claim: Claim {
            id: 3592,
            claimee: contract_address_const::<
                827929506653898309809051765272831150759947744606852950844797791651878826782
            >(),
            amount: 1001271836113844608,
        },
        proof: array![
            999107061513787509684635393322981468422914789854841379477747793466442449935,
            515922882550246450639433632126072568380885235399474989388432279023063245887,
            2183670702902438880162847431850472734321860550216187087562069279528995144858,
            15651848759914294392773788266993460012436498803878911309497344547864396458,
            681329051542701608410442131965439826537794833969063315276363661924591621130,
            3136244998269470531984442468315391698901695607768566301585234761964804893655,
            2778542412084971505948237227833424078439670112778918680530473881654242267636,
            1664390236282514480745387082230901158164058685736963812907939026964512035529,
            2315326196699957769855383121961607281382192717308836542377578681714910420282,
            2382716371051479826678099165037038065721763275238547296230775213540032250366,
            775413931716626428851693665000522046203123080573891636225659041253540837203,
            1844857354889111805724320956769488995432351795269595216315100679068515517971
        ]
    );
}

#[test]
fn test_claim_from_end_of_tree_large() {
    test_claim_is_valid(
        root: 405011783278363798212920545986279540950667137059008708904434915300742585819,
        claim: Claim {
            id: 16605,
            claimee: contract_address_const::<
                284836135682475739559347904100664354678769084599508066858400818369306251115
            >(),
            amount: 1000080194694973312,
        },
        proof: array![
            3584994958232786110573847189435462679736813679574169859276708512901684459908,
            3456560767569876651615908793256283805842107509530334958473406784224175394481,
            576973065814431626081993410573073322558132970018343395866696785754848554185,
            736107990262848904714315972898063881018050115073309434649053444309959183221,
            2021163002815443628933626434693228945243297172164470801936592396663555877826,
            2901589040842703364427753471773264798075947637844829636061501293319979431640,
            3293774020270833566793904790401762833702670186284119531755070600268368741925,
            160674685665120746028095836066282924500059590244854318435384160229157963763,
            2839570568016896630097863196252956147067067637781804601680059249176605149835,
            1870088898022793000041170914738822183912185184028239464557428700062425279227,
            271505888377476822812366281446524851149674339669641575685919848919662124896,
            3391878612706733042690751883383139274310601469785669990192514358124091696985,
            1858283206563877188634011031115620633400912073664087333553401439891983671978,
            653009678825348308131020658113913238736663469737876248844258093567627009338,
            1776702285563761589028945262957253286857459730675857906935919165166876058497
        ]
    );
}

#[test]
fn test_claim_from_end_of_tree_middle_of_bitmap() {
    test_claim_is_valid(
        root: 405011783278363798212920545986279540950667137059008708904434915300742585819,
        claim: Claim {
            id: 16567,
            claimee: contract_address_const::<
                1748616718994798723044863281884565737514860606804556124091102474369748521947
            >(),
            amount: 1005026355664803840,
        },
        proof: array![
            577779429737926850673034182197562601348556455795160762160509490274702911309,
            3531956498125196032888119207616455741869865921010213747115240525082947964487,
            2515825962787606228786524382243188502433378049561987247415362987154981448571,
            3316670161889032026226037747433331224604549957491601814857297557140704540764,
            211583343697216472970992442436522301103449739328892936330405180665115266222,
            2016634616917323403993677865627397960725479662042496998096798462521905866406,
            567154639474675754849449940276760355068200176296841726121206582800434130638,
            160674685665120746028095836066282924500059590244854318435384160229157963763,
            2839570568016896630097863196252956147067067637781804601680059249176605149835,
            1870088898022793000041170914738822183912185184028239464557428700062425279227,
            271505888377476822812366281446524851149674339669641575685919848919662124896,
            3391878612706733042690751883383139274310601469785669990192514358124091696985,
            1858283206563877188634011031115620633400912073664087333553401439891983671978,
            653009678825348308131020658113913238736663469737876248844258093567627009338,
            1776702285563761589028945262957253286857459730675857906935919165166876058497
        ]
    );
}

#[test]
fn test_double_claim_from_generated_tree() {
    test_claim_is_valid(
        root: 2413984000256568988735068618807996871735886303454043475744972321149068137869,
        claim: Claim {
            id: 0,
            claimee: contract_address_const::<
                1257981684727298919953780547925609938727371268283996697135018561811391002099
            >(),
            amount: 845608158412629999616,
        },
        proof: array![
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

#[test]
fn test_double_claim_after_other_claim() {
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

    let token = deploy_token(get_contract_address(), claim_0.amount.into() + claim_1.amount.into());

    let root = 2413984000256568988735068618807996871735886303454043475744972321149068137869;
    let airdrop = deploy(token.contract_address, root);

    token.transfer(airdrop.contract_address, claim_0.amount.into() + claim_1.amount.into());

    assert_eq!(
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
                    .span()
            ),
        true
    );

    assert_eq!(
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
                    .span()
            ),
        true
    );

    // double claim of claim id 1
    assert_eq!(
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
                    .span()
            ),
        false
    );
}

#[test]
#[should_panic(
    expected: ('INSUFFICIENT_TRANSFER_BALANCE', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
)]
fn test_claim_before_funded() {
    let claim_0 = Claim {
        id: 0,
        claimee: contract_address_const::<
            1257981684727298919953780547925609938727371268283996697135018561811391002099
        >(),
        amount: 845608158412629999616,
    };

    let token = deploy_token(get_contract_address(), 0);

    let root = 2413984000256568988735068618807996871735886303454043475744972321149068137869;
    let airdrop = deploy(token.contract_address, root);

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
                .span()
        );
}

#[test]
fn test_multiple_claims_from_generated_tree() {
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

    let token = deploy_token(get_contract_address(), claim_0.amount.into() + claim_1.amount.into());

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
                .span()
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
                .span()
        );
    let log = pop_log::<Airdrop::Claimed>(airdrop.contract_address).unwrap();
    assert_eq!(log.claim, claim_0);
}


#[test]
#[should_panic(expected: ('FIRST_CLAIM_MUST_BE_MULT_128', 'ENTRYPOINT_FAILED'))]
fn test_claim_128_fails_if_not_id_aligned() {
    let token = deploy_token(get_contract_address(), 1234567);

    let claim_a = Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, };
    let claim_b = Claim { id: 1, claimee: contract_address_const::<3456>(), amount: 789, };

    let leaf_a = hash_claim(claim_a);
    let leaf_b = hash_claim(claim_b);

    let root = hash_function(leaf_a, leaf_b);

    let airdrop = deploy(token.contract_address, root);

    airdrop.claim_128(array![claim_b, claim_a].span(), array![].span());
}


#[test]
#[should_panic(expected: ('CLAIMS_EMPTY', 'ENTRYPOINT_FAILED'))]
fn test_claim_128_empty() {
    let token = deploy_token(get_contract_address(), 1234567);

    let airdrop = deploy(token.contract_address, 0);

    airdrop.claim_128(array![].span(), array![].span());
}

#[test]
#[should_panic(expected: ('TOO_MANY_CLAIMS', 'ENTRYPOINT_FAILED'))]
fn test_claim_128_too_many_claims() {
    let token = deploy_token(get_contract_address(), 1234567);

    let airdrop = deploy(token.contract_address, 0);

    let mut claims: Array<Claim> = array![];
    let mut i: u64 = 0;
    while i < 129 {
        claims.append(Claim { id: 0, claimee: contract_address_const::<2345>(), amount: 6789, });
        i += 1;
    };

    airdrop.claim_128(claims.span(), array![].span());
}

#[test]
fn test_claim_128_large_tree() {
    let mut i: u64 = 0;

    let mut claims: Array<Claim> = array![];

    while (i < 320) {
        claims.append(Claim { id: i, amount: 3, claimee: contract_address_const::<0xcdee>() });
        i += 1;
    };

    let s1 = compute_root_of_group(claims.span().slice(0, 128));
    let s2 = compute_root_of_group(claims.span().slice(128, 128));
    let s3 = compute_root_of_group(claims.span().slice(256, 64));

    let rl = hash_function(s1, s2);
    let rr = hash_function(s3, s3);
    let root = hash_function(rl, rr);

    let token = deploy_token(get_contract_address(), 960);
    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 960);

    assert_eq!(airdrop.claim_128(claims.span().slice(0, 128), array![s2, rr].span()), 128);
    assert_eq!(airdrop.claim_128(claims.span().slice(128, 128), array![s1, rr].span()), 128);
    assert_eq!(airdrop.claim_128(claims.span().slice(256, 64), array![s3, rl].span()), 64);
}

#[test]
fn test_claim_128_double_claim() {
    let mut i: u64 = 0;

    let mut claims: Array<Claim> = array![];

    while (i < 320) {
        claims.append(Claim { id: i, amount: 3, claimee: contract_address_const::<0xcdee>() });
        i += 1;
    };

    let s1 = compute_root_of_group(claims.span().slice(0, 128));
    let s2 = compute_root_of_group(claims.span().slice(128, 128));
    let s3 = compute_root_of_group(claims.span().slice(256, 64));

    let rl = hash_function(s1, s2);
    let rr = hash_function(s3, s3);
    let root = hash_function(rl, rr);

    let token = deploy_token(get_contract_address(), 960);
    let airdrop = deploy(token.contract_address, root);
    token.transfer(airdrop.contract_address, 960);

    assert_eq!(airdrop.claim_128(claims.span().slice(0, 128), array![s2, rr].span()), 128);
    let mut i: u64 = 0;
    while let Option::Some(claimed) =
        pop_log::<
            Airdrop::Claimed
        >(airdrop.contract_address) {
            assert_eq!(
                claimed.claim,
                Claim { id: i, amount: 3, claimee: contract_address_const::<0xcdee>() }
            );
            i += 1;
        };

    assert_eq!(airdrop.claim_128(claims.span().slice(0, 128), array![s2, rr].span()), 0);
    assert_eq!(pop_log::<Airdrop::Claimed>(airdrop.contract_address).is_none(), true);
}
