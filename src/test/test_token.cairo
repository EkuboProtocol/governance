use governance::interfaces::erc20::{IERC20Dispatcher};
use starknet::{ContractAddress, syscalls::{deploy_syscall}};

#[starknet::contract]
pub(crate) mod TestToken {
    use core::num::traits::zero::{Zero};
    use governance::interfaces::erc20::{IERC20};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        balances: LegacyMap<ContractAddress, u256>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u256>,
    }

    #[derive(starknet::Event, PartialEq, Debug, Drop)]
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
    fn constructor(ref self: ContractState, recipient: ContractAddress, amount: u256) {
        self.balances.write(recipient, amount);
        self.emit(Transfer { from: Zero::zero(), to: recipient, value: amount })
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
            let balance = self.balances.read(get_caller_address());
            assert(balance >= amount, 'INSUFFICIENT_TRANSFER_BALANCE');
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.balances.write(get_caller_address(), balance - amount);
            self.emit(Transfer { from: get_caller_address(), to: recipient, value: amount });
            true
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let allowance = self.allowances.read((sender, get_caller_address()));
            assert(allowance >= amount, 'INSUFFICIENT_ALLOWANCE');
            let balance = self.balances.read(sender);
            assert(balance >= amount, 'INSUFFICIENT_TF_BALANCE');
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.balances.write(sender, balance - amount);
            self.allowances.write((sender, get_caller_address()), allowance - amount);
            self.emit(Transfer { from: sender, to: recipient, value: amount });
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.allowances.write((get_caller_address(), spender), amount.try_into().unwrap());
            true
        }
    }
}

#[cfg(test)]
pub(crate) fn deploy(owner: ContractAddress, amount: u256) -> IERC20Dispatcher {
    let mut constructor_args: Array<felt252> = ArrayTrait::new();
    Serde::serialize(@(owner, amount), ref constructor_args);

    let (address, _) = deploy_syscall(
        TestToken::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_args.span(), true
    )
        .expect('DEPLOY_TOKEN_FAILED');
    IERC20Dispatcher { contract_address: address }
}
