use core::option::OptionTrait;
use starknet::{ContractAddress};

pub(crate) fn recipient() -> ContractAddress {
    'recipient'.try_into().unwrap()
}

pub(crate) fn proposer() -> ContractAddress {
    'proposer'.try_into().unwrap()
}

pub(crate) fn delegate() -> ContractAddress {
    'delegate'.try_into().unwrap()
}

pub(crate) fn voter() -> ContractAddress {
    'voter'.try_into().unwrap()
}

pub(crate) fn voter2() -> ContractAddress {
    'user2'.try_into().unwrap()
}

pub(crate) fn user() -> ContractAddress {
    'user'.try_into().unwrap()
}


pub(crate) fn timestamp() -> u64 {
    1688122125
}
