use core::array::{Array, Span};
use governance::interfaces::erc20::{IERC20Dispatcher};
use starknet::{ContractAddress};

#[derive(Copy, Drop, Serde, Hash, PartialEq, Debug)]
pub struct Claim {
    // the unique ID of the claim
    pub id: u64,
    // the address that will receive the token
    pub claimee: ContractAddress,
    // the amount of token the address is entitled to
    pub amount: u128,
}

#[starknet::interface]
pub trait IAirdrop<TStorage> {
    // Return the root of the airdrop
    fn get_root(self: @TStorage) -> felt252;

    // Return the token being dropped
    fn get_token(self: @TStorage) -> IERC20Dispatcher;

    // Claims the given allotment of tokens.
    // Because this method is idempotent, it does not revert in case of a second submission of the same claim. 
    // This makes it simpler to batch many claims together in a single transaction.
    // Returns true iff the claim was processed. Returns false if the claim was already claimed.
    // Panics if the proof is invalid.
    fn claim(ref self: TStorage, claim: Claim, proof: Span<felt252>) -> bool;

    // Return whether the claim with the given ID has been claimed
    fn is_claimed(self: @TStorage, claim_id: u64) -> bool;
}

#[starknet::contract]
pub mod Airdrop {
    use core::array::{ArrayTrait, SpanTrait};
    use core::hash::{LegacyHash};
    use core::num::traits::zero::{Zero};
    use core::num::traits::one::{One};
    use governance::interfaces::erc20::{IERC20DispatcherTrait};
    use governance::utils::exp2::{exp2};
    use super::{IAirdrop, ContractAddress, Claim, IERC20Dispatcher};

    #[inline(always)]
    pub(crate) fn hash_function(a: felt252, b: felt252) -> felt252 {
        let a_u256: u256 = a.into();
        if a_u256 < b.into() {
            core::pedersen::pedersen(a, b)
        } else {
            core::pedersen::pedersen(b, a)
        }
    }

    // Compute the pedersen root of a merkle tree by combining the current node with each sibling up the tree
    pub(crate) fn compute_pedersen_root(current: felt252, mut proof: Span<felt252>) -> felt252 {
        match proof.pop_front() {
            Option::Some(proof_element) => {
                compute_pedersen_root(hash_function(current, *proof_element), proof)
            },
            Option::None => { current },
        }
    }

    #[storage]
    struct Storage {
        root: felt252,
        token: IERC20Dispatcher,
        claimed_bitmap: LegacyMap<u64, u128>,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Claimed {
        pub claim: Claim
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

    #[inline(always)]
    fn claim_id_to_bitmap_index(claim_id: u64) -> (u64, u8) {
        let (word, index) = DivRem::div_rem(claim_id, 128_u64.try_into().unwrap());
        (word, index.try_into().unwrap())
    }

    #[inline(always)]
    fn hash_claim(claim: Claim) -> felt252 {
        LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim)
    }

    #[abi(embed_v0)]
    impl AirdropImpl of IAirdrop<ContractState> {
        fn get_root(self: @ContractState) -> felt252 {
            self.root.read()
        }

        fn get_token(self: @ContractState) -> IERC20Dispatcher {
            self.token.read()
        }

        fn claim(ref self: ContractState, claim: Claim, proof: Span<felt252>) -> bool {
            let leaf = hash_claim(claim);
            assert(self.root.read() == compute_pedersen_root(leaf, proof), 'INVALID_PROOF');

            // this is copied in from is_claimed because we only want to read the bitmap once
            let (word, index) = claim_id_to_bitmap_index(claim.id);
            let bitmap = self.claimed_bitmap.read(word);
            let already_claimed = (bitmap & exp2(index)).is_non_zero();

            if already_claimed {
                false
            } else {
                self.claimed_bitmap.write(word, bitmap | exp2(index.try_into().unwrap()));

                self.token.read().transfer(claim.claimee, claim.amount.into());

                self.emit(Claimed { claim });

                true
            }
        }

        fn is_claimed(self: @ContractState, claim_id: u64) -> bool {
            let (word, index) = claim_id_to_bitmap_index(claim_id);
            let bitmap = self.claimed_bitmap.read(word);
            (bitmap & exp2(index)).is_non_zero()
        }
    }
}
