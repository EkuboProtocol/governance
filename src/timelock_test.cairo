use array::{ArrayTrait};
use debug::PrintTrait;
use governance::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait, Timelock};
use starknet::{
    get_contract_address, deploy_syscall, ClassHash, contract_address_const, ContractAddress
};
use starknet::class_hash::Felt252TryIntoClassHash;
use traits::{TryInto};

use result::{Result, ResultTrait};
use option::{OptionTrait};

fn deploy() -> ITimelockDispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();

    let (address, _) = deploy_syscall(
        Timelock::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_FAILED');
    return ITimelockDispatcher { contract_address: address };
}

#[test]
#[available_gas(3000000)]
fn test_deploy() {
    let Timelock = deploy();
}
