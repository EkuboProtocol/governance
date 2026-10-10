// EKU-1261 TESTNET-ONLY T2 voting token (Starknet Sepolia). It replaces faucet STRK as the T2 Staker token so the
// T2 Governor's authority is isolated: the entire fixed supply is minted once, in the constructor, to `holder`
// (the t2-starknet account), and t2-starknet stakes all of it. There is no mint, burn, owner, admin, upgrade or
// pause; nothing can ever create more voting weight, so no third party can reach the proposal threshold or quorum.
// Never deploy on mainnet; it is not a production token.

pub const TOTAL_SUPPLY: u256 = 1_000_000_000_000_000_000_000; // 1000 * 10^18

#[starknet::interface]
pub trait IT2VotingToken<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn totalSupply(self: @TContractState) -> u256;
    fn balanceOf(self: @TContractState, account: starknet::ContractAddress) -> u256;
    fn allowance(
        self: @TContractState, owner: starknet::ContractAddress, spender: starknet::ContractAddress,
    ) -> u256;
    fn transfer(ref self: TContractState, recipient: starknet::ContractAddress, amount: u256) -> bool;
    fn transferFrom(
        ref self: TContractState,
        sender: starknet::ContractAddress,
        recipient: starknet::ContractAddress,
        amount: u256,
    ) -> bool;
    fn approve(ref self: TContractState, spender: starknet::ContractAddress, amount: u256) -> bool;
}

#[starknet::contract]
pub mod T2VotingToken {
    use core::num::traits::Zero;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::TOTAL_SUPPLY;

    #[storage]
    struct Storage {
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Transfer {
        #[key]
        pub from: ContractAddress,
        #[key]
        pub to: ContractAddress,
        pub value: u256,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub struct Approval {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub spender: ContractAddress,
        pub value: u256,
    }

    #[event]
    #[derive(starknet::Event, PartialEq, Debug, Drop)]
    pub enum Event {
        Transfer: Transfer,
        Approval: Approval,
    }

    #[constructor]
    fn constructor(ref self: ContractState, holder: ContractAddress) {
        assert(!holder.is_zero(), 'ZERO_HOLDER');
        self.balances.write(holder, TOTAL_SUPPLY);
        self.emit(Transfer { from: Zero::zero(), to: holder, value: TOTAL_SUPPLY });
    }

    #[abi(embed_v0)]
    impl T2VotingTokenImpl of super::IT2VotingToken<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            'EKU-1261 T2 Test Vote'
        }

        fn symbol(self: @ContractState) -> felt252 {
            'T2VOTE'
        }

        fn decimals(self: @ContractState) -> u8 {
            18
        }

        fn totalSupply(self: @ContractState) -> u256 {
            TOTAL_SUPPLY
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self._move(get_caller_address(), recipient, amount);
            true
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let spender = get_caller_address();
            let allowed = self.allowances.read((sender, spender));
            assert(allowed >= amount, 'INSUFFICIENT_ALLOWANCE');
            self.allowances.write((sender, spender), allowed - amount);
            self._move(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();
            assert(!spender.is_zero(), 'ZERO_SPENDER');
            self.allowances.write((owner, spender), amount);
            self.emit(Approval { owner, spender, value: amount });
            true
        }
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn _move(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256) {
            assert(!to.is_zero(), 'ZERO_RECIPIENT');
            let balance = self.balances.read(from);
            assert(balance >= amount, 'INSUFFICIENT_BALANCE');
            self.balances.write(from, balance - amount);
            self.balances.write(to, self.balances.read(to) + amount);
            self.emit(Transfer { from, to, value: amount });
        }
    }
}
