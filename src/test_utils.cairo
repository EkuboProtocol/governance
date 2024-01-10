use core::option::OptionTrait;
use starknet::{contract_address_try_from_felt252, ContractAddress};

fn recipient() -> ContractAddress {
    contract_address_try_from_felt252('recipient').unwrap()
}

fn proposer() -> ContractAddress {
    contract_address_try_from_felt252('proposer').unwrap()
}

fn delegate() -> ContractAddress {
    contract_address_try_from_felt252('delegate').unwrap()
}

fn voter() -> ContractAddress {
    contract_address_try_from_felt252('voter').unwrap()
}

fn voter2() -> ContractAddress {
    contract_address_try_from_felt252('user2').unwrap()
}

fn user() -> ContractAddress {
    contract_address_try_from_felt252('user').unwrap()
}


fn zero_address() -> ContractAddress {
    contract_address_try_from_felt252(0).unwrap()
}
fn timestamp() -> u64 {
    1688122125
}
