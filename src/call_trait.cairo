use core::array::{ArrayTrait, SpanTrait};
use core::hash::{LegacyHash, HashStateTrait, HashStateExTrait, Hash};
use core::result::{ResultTrait};
use core::traits::{Into};
use starknet::account::{Call};
use starknet::{ContractAddress};
use starknet::{SyscallResult, syscalls::call_contract_syscall};

pub impl HashCall<S, +HashStateTrait<S>, +Drop<S>, +Copy<S>> of Hash<@Call, S> {
    fn update_state(state: S, value: @Call) -> S {
        let mut s = state.update_with((*value.to)).update_with(*value.selector);

        let mut data_span: Span<felt252> = *value.calldata;
        while let Option::Some(word) = data_span.pop_front() {
            s = s.update(*word);
        };

        s
    }
}

#[generate_trait]
pub impl CallTraitImpl of CallTrait {
    fn execute(self: @Call) -> Span<felt252> {
        let result = call_contract_syscall(*self.to, *self.selector, *self.calldata);

        if (result.is_err()) {
            panic(result.unwrap_err());
        }

        result.unwrap()
    }
}

