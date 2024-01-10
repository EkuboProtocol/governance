use core::array::{Array};
use governance::interfaces::erc20::{IERC20Dispatcher};
use starknet::{ContractAddress};

#[derive(Copy, Drop, Serde, Hash, PartialEq)]
struct Claim {
    claimee: ContractAddress,
    amount: u128,
}

#[starknet::interface]
trait IAirdrop<TStorage> {
    // Claims the given allotment of tokens
    fn claim(ref self: TStorage, claim: Claim, proof: Array::<felt252>);

    // Return the root of the airdrop
    fn get_root(self: @TStorage) -> felt252;

    // Return the token being dropped
    fn get_token(self: @TStorage) -> IERC20Dispatcher;

    // Return whether the claim has been claimed (always false for invalid claims)
    fn is_claimed(self: @TStorage, claim: Claim) -> bool;
}

#[starknet::contract]
mod Airdrop {
    use core::array::{ArrayTrait, SpanTrait};
    use core::hash::{LegacyHash};
    use governance::interfaces::erc20::{IERC20DispatcherTrait};
    use starknet::{ContractAddressIntoFelt252};
    use super::{IAirdrop, ContractAddress, Claim, IERC20Dispatcher};

    fn lt<X, +Copy<X>, +Into<X, u256>>(lhs: @X, rhs: @X) -> bool {
        let a: u256 = (*lhs).into();
        let b: u256 = (*rhs).into();
        return a < b;
    }

    // Compute the pedersen root of a merkle tree by combining the current node with each sibling up the tree
    fn compute_pedersen_root(current: felt252, mut proof: Span<felt252>) -> felt252 {
        match proof.pop_front() {
            Option::Some(proof_element) => {
                compute_pedersen_root(
                    if lt(@current, proof_element) {
                        core::pedersen::pedersen(current, *proof_element)
                    } else {
                        core::pedersen::pedersen(*proof_element, current)
                    },
                    proof
                )
            },
            Option::None(()) => { current },
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
        claim: Claim
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Claimed: Claimed,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: IERC20Dispatcher, root: felt252) {
        self.root.write(root);
        self.token.write(token);
    }

    #[external(v0)]
    impl AirdropImpl of IAirdrop<ContractState> {
        fn claim(ref self: ContractState, claim: Claim, proof: Array::<felt252>) {
            let leaf = LegacyHash::hash(0, claim);

            assert(!self.claimed.read(leaf), 'ALREADY_CLAIMED');
            assert(self.root.read() == compute_pedersen_root(leaf, proof.span()), 'INVALID_PROOF');
            self.claimed.write(leaf, true);

            self.token.read().transfer(claim.claimee, u256 { high: 0, low: claim.amount });

            self.emit(Claimed { claim });
        }

        fn get_root(self: @ContractState) -> felt252 {
            self.root.read()
        }

        fn get_token(self: @ContractState) -> IERC20Dispatcher {
            self.token.read()
        }

        fn is_claimed(self: @ContractState, claim: Claim) -> bool {
            self.claimed.read(LegacyHash::hash(0, claim))
        }
    }
}
