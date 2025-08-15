use starknet::{ContractAddress, EthAddress, ClassHash};
use starknet::account::{Call};

#[starknet::interface]
pub trait IL1StakingProxy<TContractState> {
    // Returns the L1 owner address
    fn get_l1_owner(self: @TContractState) -> EthAddress;
    
    // Returns the staker contract address
    fn get_staker(self: @TContractState) -> ContractAddress;
    
    // Returns the token contract address
    fn get_token(self: @TContractState) -> ContractAddress;
    
    // Handles L1 messages for staking operations
    fn handle_l1_message(
        ref self: TContractState,
        from_address: felt252,
        payload: Span<felt252>
    );
    
    // Upgrades the contract implementation (only callable via L1 message)
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    
    // Executes arbitrary calls (only callable via L1 message)
    fn execute_calls(ref self: TContractState, calls: Span<Call>) -> Span<Span<felt252>>;
    
    // Emergency function to transfer tokens out (only callable via L1 message)
    fn emergency_transfer(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    );
}

#[derive(Drop, Serde)]
pub enum StakingOperation {
    Stake: StakeParams,
    Withdraw: WithdrawParams,
    ExecuteCalls: Span<Call>,
    Upgrade: ClassHash,
    EmergencyTransfer: EmergencyTransferParams,
}

#[derive(Drop, Serde)]
pub struct StakeParams {
    pub delegate: ContractAddress,
    pub amount: u128,
}

#[derive(Drop, Serde)]
pub struct WithdrawParams {
    pub delegate: ContractAddress,
    pub recipient: ContractAddress,
    pub amount: u128,
}

#[derive(Drop, Serde)]
pub struct EmergencyTransferParams {
    pub token: ContractAddress,
    pub recipient: ContractAddress,
    pub amount: u256,
}

#[starknet::contract]
pub mod L1StakingProxy {
    use core::num::traits::zero::{Zero};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use governance::staker::{IStakerDispatcher, IStakerDispatcherTrait};
    use governance::call_trait::{CallTrait};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{
        get_caller_address, get_contract_address,
        syscalls::{replace_class_syscall},
    };
    use super::{
        ContractAddress, EthAddress, ClassHash, Call, IL1StakingProxy,
        StakingOperation, StakeParams, WithdrawParams, EmergencyTransferParams,
    };

    #[storage]
    struct Storage {
        l1_owner: EthAddress,
        staker: IStakerDispatcher,
        token: IERC20Dispatcher,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        l1_owner: EthAddress,
        staker: IStakerDispatcher,
        token: IERC20Dispatcher,
    ) {
        self.l1_owner.write(l1_owner);
        self.staker.write(staker);
        self.token.write(token);
    }

    #[derive(starknet::Event, Drop)]
    pub struct L1MessageHandled {
        pub from_address: felt252,
        pub operation: felt252, // Hash of the operation type
    }

    #[derive(starknet::Event, Drop)]
    pub struct Staked {
        pub delegate: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Withdrawn {
        pub delegate: ContractAddress,
        pub recipient: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct CallsExecuted {
        pub calls_count: u32,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Upgraded {
        pub new_class_hash: ClassHash,
    }

    #[derive(starknet::Event, Drop)]
    pub struct EmergencyTransferExecuted {
        pub token: ContractAddress,
        pub recipient: ContractAddress,
        pub amount: u256,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        L1MessageHandled: L1MessageHandled,
        Staked: Staked,
        Withdrawn: Withdrawn,
        CallsExecuted: CallsExecuted,
        Upgraded: Upgraded,
        EmergencyTransferExecuted: EmergencyTransferExecuted,
    }

    #[generate_trait]
    impl InternalMethods of InternalMethodsTrait {
        fn assert_l1_owner(self: @ContractState, from_address: felt252) {
            assert(from_address == self.l1_owner.read().into(), 'UNAUTHORIZED_L1_CALLER');
        }

        fn execute_staking_operation(
            ref self: ContractState, operation: StakingOperation
        ) {
            match operation {
                StakingOperation::Stake(params) => {
                    self.execute_stake(params);
                },
                StakingOperation::Withdraw(params) => {
                    self.execute_withdraw(params);
                },
                StakingOperation::ExecuteCalls(calls) => {
                    self.execute_calls_internal(calls);
                },
                StakingOperation::Upgrade(class_hash) => {
                    self.execute_upgrade(class_hash);
                },
                StakingOperation::EmergencyTransfer(params) => {
                    self.execute_emergency_transfer(params);
                },
            }
        }

        fn execute_stake(ref self: ContractState, params: StakeParams) {
            let staker = self.staker.read();
            staker.stake_amount(params.delegate, params.amount);
            self.emit(Staked { delegate: params.delegate, amount: params.amount });
        }

        fn execute_withdraw(ref self: ContractState, params: WithdrawParams) {
            let staker = self.staker.read();
            staker.withdraw_amount(params.delegate, params.recipient, params.amount);
            self.emit(Withdrawn { 
                delegate: params.delegate, 
                recipient: params.recipient, 
                amount: params.amount 
            });
        }

        fn execute_calls_internal(ref self: ContractState, mut calls: Span<Call>) {
            let calls_count = calls.len();
            while let Option::Some(call) = calls.pop_front() {
                call.execute();
            };
            self.emit(CallsExecuted { calls_count });
        }

        fn execute_upgrade(ref self: ContractState, class_hash: ClassHash) {
            replace_class_syscall(class_hash).unwrap();
            self.emit(Upgraded { new_class_hash: class_hash });
        }

        fn execute_emergency_transfer(ref self: ContractState, params: EmergencyTransferParams) {
            let token = IERC20Dispatcher { contract_address: params.token };
            assert(
                token.transfer(params.recipient, params.amount),
                'EMERGENCY_TRANSFER_FAILED'
            );
            self.emit(EmergencyTransferExecuted {
                token: params.token,
                recipient: params.recipient,
                amount: params.amount,
            });
        }
    }

    #[abi(embed_v0)]
    impl L1StakingProxyImpl of IL1StakingProxy<ContractState> {
        fn get_l1_owner(self: @ContractState) -> EthAddress {
            self.l1_owner.read()
        }

        fn get_staker(self: @ContractState) -> ContractAddress {
            self.staker.read().contract_address
        }

        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read().contract_address
        }

        fn handle_l1_message(
            ref self: ContractState,
            from_address: felt252,
            mut payload: Span<felt252>
        ) {
            // Verify the message is from the authorized L1 owner
            self.assert_l1_owner(from_address);

            // Deserialize the operation from the payload
            let operation: StakingOperation = Serde::deserialize(ref payload)
                .expect('INVALID_PAYLOAD');

            // Execute the operation
            self.execute_staking_operation(operation);

            // Emit event
            self.emit(L1MessageHandled {
                from_address,
                operation: selector!("StakingOperation"), // Simple operation identifier
            });
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            // This should only be called via L1 message, but we add this check for safety
            assert(get_caller_address() == get_contract_address(), 'INTERNAL_CALL_ONLY');
            self.execute_upgrade(new_class_hash);
        }

        fn execute_calls(ref self: ContractState, calls: Span<Call>) -> Span<Span<felt252>> {
            // This should only be called via L1 message, but we add this check for safety
            assert(get_caller_address() == get_contract_address(), 'INTERNAL_CALL_ONLY');
            
            let mut results: Array<Span<felt252>> = array![];
            let mut calls_copy = calls;
            
            while let Option::Some(call) = calls_copy.pop_front() {
                results.append(call.execute());
            };

            self.emit(CallsExecuted { calls_count: calls.len() });
            results.span()
        }

        fn emergency_transfer(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            // This should only be called via L1 message, but we add this check for safety
            assert(get_caller_address() == get_contract_address(), 'INTERNAL_CALL_ONLY');
            
            self.execute_emergency_transfer(EmergencyTransferParams {
                token,
                recipient,
                amount,
            });
        }
    }

    // L1 Handler - This is the entry point for L1 messages
    #[l1_handler]
    fn handle_l1_message_entry(
        ref self: ContractState,
        from_address: felt252,
        payload: Span<felt252>
    ) {
        self.handle_l1_message(from_address, payload);
    }
}
