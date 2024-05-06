use core::array::{ArrayTrait};
use core::option::{OptionTrait};

use core::result::{Result};
use core::traits::{TryInto};
use governance::execution_state::{ExecutionState};
use governance::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, Factory, DeploymentParameters, DeploymentResult,
};
use governance::factory_test::{deploy as deploy_factory};
use governance::governor::{Config as GovernorConfig};
use governance::governor::{Governor};
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
                voting_start_delay: 86400,
                voting_period: 604800,
                voting_weight_smoothing_duration: 43200,
                quorum: 500,
                proposal_creation_threshold: 50,
            },
            timelock_config: TimelockConfig { delay: 259200, window: 86400 }
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

    fn create_proposal_from(self: @Setup, delegate: ContractAddress, call: Call) -> felt252 {
        let address_before = get_contract_address();
        set_contract_address(delegate);
        let id = (*self.deployment.governor).propose(call);
        set_contract_address(address_before);
        id
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
#[should_panic(expected: ('NO_MAJORITY', 'ENTRYPOINT_FAILED'))]
fn test_create_proposal_that_fails() {
    let s = setup(Option::None);
    let delegate_yes = contract_address_const::<1234>();
    let delegate_no = contract_address_const::<2345>();

    let delegated_amount = s.deployment.governor.get_config().quorum;
    s.delegate_amount(delegate_yes, delegated_amount);
    s.delegate_amount(delegate_no, delegated_amount + 1);

    advance_time(s.deployment.governor.get_config().voting_weight_smoothing_duration);
    let id = s
        .create_proposal_from(
            delegate_yes,
            Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() }
        );

    advance_time(s.deployment.governor.get_config().voting_start_delay);
    s.vote_from(delegate_yes, id, true);
    s.vote_from(delegate_no, id, false);

    let proposal_info = s.deployment.governor.get_proposal(id);

    assert_eq!(proposal_info.proposer, delegate_yes);
    assert_eq!(
        proposal_info.execution_state,
        ExecutionState {
            created: start_time
                + s.deployment.governor.get_config().voting_weight_smoothing_duration,
            executed: 0,
            canceled: 0
        }
    );
    assert_eq!(proposal_info.yea, delegated_amount);
    assert_eq!(proposal_info.nay, delegated_amount + 1);

    advance_time(s.deployment.governor.get_config().voting_period);
    s
        .deployment
        .governor
        .execute(
            id, Call { to: delegate_yes, selector: 'wont-succeed', calldata: array![].span() }
        );
}
