#[starknet::contract]
pub(crate) mod TestToken {
    use core::num::traits::zero::{Zero};
    use governance::interfaces::erc20::{IERC20};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        balances: LegacyMap<ContractAddress, u128>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u128>,
    }

    #[derive(starknet::Event, Drop)]
    pub(crate) struct Transfer {
        pub(crate) from: ContractAddress,
        pub(crate) to: ContractAddress,
        pub(crate) value: u256,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Transfer: Transfer,
    }

    #[constructor]
    fn constructor(ref self: ContractState, recipient: ContractAddress, amount: u128) {
        self.balances.write(recipient, amount);
        self.emit(Transfer { from: Zero::zero(), to: recipient, value: amount.into() })
    }

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account).into()
        }
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender)).into()
        }
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let amount_small: u128 = amount.try_into().unwrap();
            let balance = self.balances.read(get_caller_address());
            self.balances.write(recipient, self.balances.read(recipient) + amount_small);
            self.balances.write(get_caller_address(), balance - amount_small);
            self.emit(Transfer { from: get_caller_address(), to: recipient, value: amount });
            true
        }
        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            true
        }
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.allowances.write((get_caller_address(), spender), amount.try_into().unwrap());
            true
        }
    }
}
