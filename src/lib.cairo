pub mod airdrop;
mod airdrop_claim_check;
#[cfg(test)]
// mod airdrop_test;

pub mod call_trait;
#[cfg(test)]
mod call_trait_test;

pub mod execution_state;
#[cfg(test)]
mod execution_state_test;

pub mod governor;
// #[cfg(test)]
// mod governor_test;

pub mod staker;
#[cfg(test)]
mod staker_test;

pub mod staker_log;
#[cfg(test)]
pub mod staker_log_test;


mod interfaces {
    pub(crate) mod erc20;
}
mod utils {
    pub(crate) mod exp2;
    pub(crate) mod fp;
    #[cfg(test)]
    pub(crate) mod fp_test;
}

#[cfg(test)]
mod test {
    pub(crate) mod test_token;
}

