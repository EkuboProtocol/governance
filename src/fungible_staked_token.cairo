use starknet::{ContractAddress};

#[starknet::interface]
pub trait IFungibleStakedToken<TContractState> {
    // Returns the address of the staker that this staked token wrapper uses
    fn get_staker(self: @TContractState) -> ContractAddress;

    // Returns the address of the token that this fungible staked wrapper stakes
    fn get_token(self: @TContractState) -> ContractAddress;

    // Returns the total number of tokens currently staked
    fn get_total_staked(self: @TContractState) -> u128;

    // The number of seconds (while total staked > 0) that have passed per total tokens staked
    // Can be used to compute the share of total staked tokens that a user has had over a period, by collecting two snapshots of the value
    fn get_seconds_per_total_staked(self: @TContractState) -> felt252;

    // Delegates any staked tokens from the caller to the owner
    fn delegate(ref self: TContractState, to: ContractAddress);

    // Get the address to whom the owner is delegated to
    fn get_delegated_to(self: @TContractState, owner: ContractAddress) -> ContractAddress;

    // Transfers the approved amount of the staked token to this contract and mints an ERC20 representing the staked amount
    fn deposit(ref self: TContractState);

    // Same as above but with a specified amount
    fn deposit_amount(ref self: TContractState, amount: u128);

    // Withdraws the entire staked balance from the contract from the caller
    fn withdraw(ref self: TContractState);

    // Withdraws the specified amount of token from the contract from the caller
    fn withdraw_amount(ref self: TContractState, amount: u128);
}

#[starknet::contract]
pub mod FungibleStakedToken {
    use core::num::traits::zero::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{Into, TryInto};
    use governance::interfaces::erc20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp};
    use super::{IFungibleStakedToken, ContractAddress};

    #[storage]
    struct Storage {
        staker: IStakerDispatcher,
        delegated_to: LegacyMap<ContractAddress, ContractAddress>,
        // The total number of tokens currently deposited
        total_staked: u128,
        last_seconds_per_total_staked_time: u64,
        seconds_per_total_staked: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, staker: IStakerDispatcher) {
        self.staker.write(staker);
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Deposit {
        pub from: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Withdrawal {
        pub from: ContractAddress,
        pub amount: u128,
    }


    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Delegation {
        pub from: ContractAddress,
        pub to: ContractAddress,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        Delegation: Delegation,
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn move_delegates(
            self: @ContractState, from: ContractAddress, to: ContractAddress, amount: u128
        ) {
            let staker = self.staker.read();
            let token = IERC20Dispatcher { contract_address: staker.get_token() };

            staker.withdraw_amount(from, get_contract_address(), amount);
            token.approve(staker.contract_address, amount.into());
            staker.stake(to);
        }
    }

    #[abi(embed_v0)]
    impl FungibleStakedTokenERC20 of IERC20<ContractState> {}

    #[abi(embed_v0)]
    impl FungibleStakedTokenImpl of IFungibleStakedToken<ContractState> {
        fn get_staker(self: @ContractState) -> ContractAddress {
            self.staker.read().contract_address
        }

        fn get_token(self: @ContractState) -> ContractAddress {
            self.staker.read().get_token()
        }

        fn delegate(ref self: ContractState, to: ContractAddress) {
            let caller = get_caller_address();
            let previous_delegated_to = self.delegated_to.read(caller);
            self.delegated_to.write(caller, to);
            self
                .move_delegates(
                    previous_delegated_to, to, self.balanceOf(caller).try_into().unwrap()
                )
        }

        fn get_delegated_to(self: @ContractState, owner: ContractAddress) -> ContractAddress {
            self.delegated_to.read(owner)
        }

        fn get_total_staked(self: @ContractState) -> u128 {
            self.total_staked.read()
        }

        fn get_seconds_per_total_staked(self: @ContractState) -> felt252 {
            let time_since_last = get_block_timestamp()
                - self.last_seconds_per_total_staked_time.read();
            if time_since_last.is_zero() {
                self.seconds_per_total_staked.read()
            } else {
                let current_staked = self.total_staked.read();
                let last_cumulative = self.seconds_per_total_staked.read();
                if current_staked.is_zero() {
                    last_cumulative
                } else {
                    last_cumulative
                        + (u256 { high: time_since_last.into(), low: 0 } / current_staked.into())
                            .try_into()
                            .unwrap()
                }
            }
        }
    }
}
