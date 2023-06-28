use starknet::ContractAddress;
use array::{Array};

#[starknet::interface]
trait IAirdrop<TStorage> {
    fn claim(ref self: TStorage, claimee: ContractAddress, amount: u128, proof: Array::<felt252>);
}

#[starknet::contract]
mod Airdrop {
    use super::{IAirdrop, ContractAddress};
    use array::{ArrayTrait, SpanTrait};
    use hash::{pedersen};
    use traits::{Into, TryInto};
    use starknet::ContractAddressIntoFelt252;

    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

    // Compute the pedersen root by combining the node with the 
    fn compute_pedersen_root(mut current: felt252, mut proof: Span<felt252>) -> felt252 {
        match proof.pop_front() {
            Option::Some(proof_element) => {
                let a: u256 = current.into();
                let b: u256 = (*proof_element).into();
                if b > a {
                    current = pedersen(current, *proof_element);
                } else {
                    current = pedersen(*proof_element, current);
                }

                compute_pedersen_root(current, proof)
            },
            Option::None(()) => {
                current
            },
        }
    }

    #[storage]
    struct Storage {
        root: felt252,
        token: IERC20Dispatcher,
        claimed: LegacyMap<felt252, bool>,
    }

    #[derive(Drop, starknet::Event)]
    struct Claimed {
        claimee: ContractAddress,
        amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Claimed: Claimed, 
    }

    #[constructor]
    fn constructor(ref self: ContractState, root: felt252, token: IERC20Dispatcher) {
        self.root.write(root);
        self.token.write(token);
    }

    #[external(v0)]
    impl AirdropImpl of IAirdrop<ContractState> {
        fn claim(
            ref self: ContractState, claimee: ContractAddress, amount: u128, proof: Array::<felt252>
        ) {
            let leaf = pedersen(claimee.into(), amount.into());
            assert(!self.claimed.read(leaf), 'ALREADY_CLAIMED');
            assert(self.root.read() == compute_pedersen_root(leaf, proof.span()), 'INVALID_PROOF');
            self.claimed.write(leaf, true);

            self.token.read().transfer(claimee, u256 { high: 0, low: amount });

            self.emit(Event::Claimed(Claimed { claimee, amount }));
        }
    }
}
