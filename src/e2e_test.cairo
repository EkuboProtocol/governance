use core::array::{ArrayTrait};
use core::option::{OptionTrait};

use core::result::{Result};
use core::traits::{TryInto};
use governance::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, Factory, DeploymentParameters, DeploymentResult,
};
use governance::factory_test::{deploy as deploy_factory};
use governance::governor::{Config as GovernorConfig, ProposalTimestamps};
use governance::governor::{Governor, Governor::{to_call_id}};
use governance::governor::{IGovernorDispatcherTrait};
use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use governance::staker::{Staker, IStakerDispatcherTrait};
use governance::test::test_token::{deploy as deploy_token};
use governance::timelock::{Timelock, ITimelockDispatcherTrait, Config as TimelockConfig};
use starknet::account::{Call};
use starknet::testing::{set_contract_address, set_block_timestamp, pop_log};
use starknet::{
    get_contract_address, syscalls::deploy_syscall, ClassHash, contract_address_const,
    ContractAddress, get_block_timestamp
};

#[derive(Copy, Drop)]
struct Setup {
    time: u64,
    token: IERC20Dispatcher,
    deployment: DeploymentResult
}

fn faucet() -> ContractAddress {
    contract_address_const::<'faucet'>()
}

impl DefaultDeploymentParameters of Default<DeploymentParameters> {
    fn default() -> DeploymentParameters {
        DeploymentParameters {
            governor_config: GovernorConfig {
                voting_start_delay: 30,
                voting_period: 60,
                voting_weight_smoothing_duration: 10,
                quorum: 100,
                proposal_creation_threshold: 20
            },
            timelock_config: TimelockConfig { delay: 30, window: 90, },
        }
    }
}

const start_time: u64 = 1710274866;

fn setup(options: Option<DeploymentParameters>) -> Setup {
    set_block_timestamp(start_time);

    let token = deploy_token(faucet(), 0xffffffffffffffffffffffffffffffff);
    let factory = deploy_factory();
    Setup {
        time: get_block_timestamp(),
        token,
        deployment: factory.deploy(token.contract_address, options.unwrap_or_default())
    }
}

#[generate_trait]
impl SetupTraitImpl of SetupTrait {
    fn delegate_amount(self: @Setup, delegate: ContractAddress, amount: u128) {
        let address_before = get_contract_address();

        set_contract_address(faucet());
        (*self.token).transfer(delegate, amount.into());
        set_contract_address(delegate);
        (*self.token).approve((*self.deployment).staker.contract_address, amount.into());
        (*self.deployment).staker.stake(delegate);

        set_contract_address(address_before);
    }

    fn create_proposal_from(self: @Setup, delegate: ContractAddress, call: Call) {
        let address_before = get_contract_address();
        set_contract_address(delegate);
        (*self.deployment.governor).propose(call);
        set_contract_address(address_before);
    }

    fn vote_from(self: @Setup, delegate: ContractAddress, id: felt252, yea: bool) {
        let address_before = get_contract_address();
        set_contract_address(delegate);
        (*self.deployment.governor).vote(id, yea);
        set_contract_address(address_before);
    }
}

fn advance_time(offset: u64) {
    set_block_timestamp(get_block_timestamp() + offset);
}

#[test]
fn test_delegated_amount_grows_over_time() {
    let s = setup(Option::None);
    let delegate = contract_address_const::<1234>();

    s.delegate_amount(delegate, 123);
    assert_eq!(s.deployment.staker.get_delegated(delegate), 123);
    assert_eq!(s.deployment.staker.get_average_delegated_over_last(delegate, 30), 0);

    advance_time(15);
    assert_eq!(s.deployment.staker.get_average_delegated_over_last(delegate, 30), 61);

    advance_time(15);
    assert_eq!(s.deployment.staker.get_average_delegated_over_last(delegate, 30), 123);
}

#[test]
#[should_panic(expected: ('NO_MAJORITY', 'ENTRYPOINT_FAILED'))]
fn test_create_proposal_that_fails() {
    let s = setup(Option::None);
    let delegate_yes = contract_address_const::<1234>();
    let delegate_no = contract_address_const::<2345>();

    s.delegate_amount(delegate_yes, 100);
    s.delegate_amount(delegate_no, 101);

    advance_time(30);
    s
        .create_proposal_from(
            delegate_yes,
            Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() }
        );

    let id = to_call_id(
        @Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() }
    );

    advance_time(30);
    s.vote_from(delegate_yes, id, true);
    s.vote_from(delegate_no, id, false);

    let proposal_info = s
        .deployment
        .governor
        .get_proposal(
            to_call_id(
                @Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() }
            )
        );

    assert_eq!(proposal_info.proposer, delegate_yes);
    assert_eq!(
        proposal_info.timestamps, ProposalTimestamps { created: start_time + 30, executed: 0 }
    );
    assert_eq!(proposal_info.yea, 100);
    assert_eq!(proposal_info.nay, 101);

    advance_time(60);
    s
        .deployment
        .governor
        .execute(Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() });
}
