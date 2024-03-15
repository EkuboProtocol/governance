use core::array::{ArrayTrait};
use core::option::{OptionTrait};

use core::result::{Result};
use core::traits::{TryInto};
use governance::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, Factory, DeploymentParameters,
};
use governance::governor::{Config as GovernorConfig};
use governance::governor::{Governor};
use governance::governor::{IGovernorDispatcherTrait};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{Staker, IStakerDispatcherTrait};
use governance::timelock::{Timelock, ITimelockDispatcherTrait, TimelockConfig};
use starknet::testing::{set_contract_address, set_block_timestamp, pop_log};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress,
};

pub(crate) fn deploy() -> IFactoryDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(
        @(Staker::TEST_CLASS_HASH, Governor::TEST_CLASS_HASH, Timelock::TEST_CLASS_HASH),
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
fn test_deploy() {
    let factory = deploy();

    let token = contract_address_const::<0xabcdef>();

    let result = factory
        .deploy(
            token,
            DeploymentParameters {
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

    assert_eq!(result.staker.get_token(), token);

    assert_eq!(result.governor.get_staker().contract_address, result.staker.contract_address);
    assert_eq!(
        result.governor.get_config(),
        GovernorConfig {
            voting_start_delay: 0,
            voting_period: 180,
            voting_weight_smoothing_duration: 30,
            quorum: 1000,
            proposal_creation_threshold: 100,
        }
    );
    assert_eq!(result.timelock.get_configuration().delay, 320);
    assert_eq!(result.timelock.get_configuration().window, 60);
}
