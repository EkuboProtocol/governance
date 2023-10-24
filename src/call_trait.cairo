use starknet::{ContractAddress, ContractAddressIntoFelt252};
use array::{ArrayTrait, SpanTrait};
use traits::{Into};
use hash::{LegacyHash};
use starknet::{SyscallResult, syscalls::call_contract_syscall};
use starknet::account::{Call};
use result::{ResultTrait};

impl HashCall<S, +hash::HashStateTrait<S>, +Drop<S>, +Copy<S>> of hash::Hash<@Call, S> {
    fn update_state(state: S, value: @Call) -> S {
        let mut s = state.update((*value.to).into()).update(*value.selector);

        let mut data_span = value.calldata.span();
        loop {
            match data_span.pop_front() {
                Option::Some(word) => { s = s.update(*word); },
                Option::None => { break; }
            };
        };

        s
    }
}

#[generate_trait]
impl CallTraitImpl of CallTrait {
    fn execute(self: @Call) -> Span<felt252> {
        let result = call_contract_syscall(*self.to, *self.selector, self.calldata.span());

        if (result.is_err()) {
            panic(result.unwrap_err());
        }

        result.unwrap()
    }
}

