use core::array::{ArrayTrait};
use core::option::{OptionTrait};

use core::result::{Result, ResultTrait};
use core::traits::{TryInto};
use governance::airdrop::{Airdrop};
use governance::airdrop::{IAirdropDispatcherTrait};
use governance::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, Factory, DeploymentParameters, AirdropConfig,
};
use governance::governance_token::{GovernanceToken};
use governance::governance_token::{IGovernanceTokenDispatcherTrait};
use governance::governor::{Config as GovernorConfig};
use governance::governor::{Governor};
use governance::governor::{IGovernorDispatcherTrait};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::timelock::{Timelock, ITimelockDispatcherTrait, TimelockConfig};
use starknet::class_hash::{Felt252TryIntoClassHash};
use starknet::testing::{set_contract_address, set_block_timestamp, pop_log};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress,
};

fn deploy() -> IFactoryDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(
        @(
            GovernanceToken::TEST_CLASS_HASH,
            Airdrop::TEST_CLASS_HASH,
            Governor::TEST_CLASS_HASH,
            Timelock::TEST_CLASS_HASH
        ),
        ref constructor_args
    );

    let (address, _) = deploy_syscall(
        class_hash: Factory::TEST_CLASS_HASH.try_into().unwrap(),
        contract_address_salt: 0,
        calldata: constructor_args.span(),
        deploy_from_zero: true
    )
        .expect('DEPLOY_FAILED');
    return IFactoryDispatcher { contract_address: address };
}


#[test]
#[available_gas(30000000)]
fn test_deploy() {
    let factory = deploy();

    let result = factory
        .deploy(
            DeploymentParameters {
                name: 'token',
                symbol: 'tk',
                total_supply: 5678,
                airdrop_config: Option::Some(AirdropConfig { root: 'root', total: 1111 }),
                governor_config: GovernorConfig {
                    voting_start_delay: 0,
                    voting_period: 180,
                    voting_weight_smoothing_duration: 30,
                    quorum: 1000,
                    proposal_creation_threshold: 100,
                },
                timelock_config: TimelockConfig { delay: 320, window: 60, }
            }
        );

    let erc20 = IERC20Dispatcher { contract_address: result.token.contract_address };

    assert(erc20.name() == 'token', 'name');
    assert(erc20.symbol() == 'tk', 'symbol');
    assert(erc20.decimals() == 18, 'decimals');
    assert(erc20.totalSupply() == 5678, 'totalSupply');
    assert(erc20.balance_of(get_contract_address()) == 5678 - 1111, 'deployer balance');
    assert(erc20.balance_of(result.airdrop.unwrap().contract_address) == 1111, 'airdrop balance');

    let drop = result.airdrop.unwrap();
    assert(drop.get_root() == 'root', 'airdrop root');
    assert(drop.get_token().contract_address == result.token.contract_address, 'airdrop token');

    assert(
        result.governor.get_voting_token().contract_address == result.token.contract_address,
        'voting_token'
    );
    assert(
        result
            .governor
            .get_config() == GovernorConfig {
                voting_start_delay: 0,
                voting_period: 180,
                voting_weight_smoothing_duration: 30,
                quorum: 1000,
                proposal_creation_threshold: 100,
            },
        'governor.config'
    );
    assert(result.timelock.get_configuration().delay == 320, 'timelock config (delay)');
    assert(result.timelock.get_configuration().window == 60, 'timelock config (window)');
}
