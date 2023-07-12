use starknet::{contract_address_try_from_felt252, ContractAddress};
use option::OptionTrait;

fn recipient() -> ContractAddress {
    contract_address_try_from_felt252('recipient').unwrap()
}

fn proposer() -> ContractAddress {
    contract_address_try_from_felt252('proposer').unwrap()
}

fn delegate() -> ContractAddress {
    contract_address_try_from_felt252('delegate').unwrap()
}

fn timestamp() -> u64 {
    1688122125
}
