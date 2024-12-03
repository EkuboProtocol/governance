use core::hash::{Hash, HashStateTrait};
use starknet::account::{Call};
use starknet::syscalls::{call_contract_syscall};

// Care must be taken when using this implementation: Serde of the type T must be safe for hashing.
// This means that no two values of type T have the same serialization.
pub(crate) impl HashSerializable<T, S, +Serde<T>, +HashStateTrait<S>, +Drop<S>> of Hash<@T, S> {
    fn update_state(mut state: S, value: @T) -> S {
        let mut arr = array![];
        Serde::serialize(value, ref arr);
        state = state.update(arr.len().into());
        while let Option::Some(word) = arr.pop_front() {
            state = state.update(word)
        };

        state
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

