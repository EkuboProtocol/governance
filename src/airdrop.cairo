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

    // Claims the batch of up to 128 claims that must be aligned with a single bitmap, i.e. the id of the first must be a multiple of 128
    // and the claims should be sequentially in order. The proof verification is optimized in this method.
    // Returns the number of claims that were executed
    fn claim_128(ref self: TStorage, claims: Span<Claim>, remaining_proof: Span<felt252>) -> u8;

    // Return whether the claim with the given ID has been claimed
    fn is_claimed(self: @TStorage, claim_id: u64) -> bool;
}

#[starknet::contract]
pub mod Airdrop {
    use core::array::{ArrayTrait, SpanTrait};
    use core::hash::{LegacyHash};
    use core::num::traits::one::{One};
    use core::num::traits::zero::{Zero};
    use governance::interfaces::erc20::{IERC20DispatcherTrait};
    use governance::utils::exp2::{exp2};
    use super::{IAirdrop, ContractAddress, Claim, IERC20Dispatcher};


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

    const BITMAP_SIZE: NonZero<u64> = 128;

    fn claim_id_to_bitmap_index(claim_id: u64) -> (u64, u8) {
        let (word, index) = DivRem::div_rem(claim_id, BITMAP_SIZE);
        (word, index.try_into().unwrap())
    }

    pub fn hash_claim(claim: Claim) -> felt252 {
        LegacyHash::hash(selector!("ekubo::governance::airdrop::Claim"), claim)
    }

    pub fn compute_root_of_group(mut claims: Span<Claim>) -> felt252 {
        assert(!claims.is_empty(), 'NO_CLAIMS');

        let mut claim_hashes: Array<felt252> = ArrayTrait::new();

        let mut last_claim_id: Option<u64> = Option::None;

        while let Option::Some(claim) = claims
            .pop_front() {
                if let Option::Some(last_id) = last_claim_id {
                    assert(last_id == (*claim.id - 1), 'SEQUENTIAL');
                };

                claim_hashes.append(hash_claim(*claim));
                last_claim_id = Option::Some(*claim.id);
            };

        // will eventually contain an array of length 1
        let mut current_layer: Span<felt252> = claim_hashes.span();

        while current_layer
            .len()
            .is_non_one() {
                let mut next_layer: Array<felt252> = ArrayTrait::new();

                while let Option::Some(hash) = current_layer
                    .pop_front() {
                        next_layer
                            .append(
                                hash_function(*hash, *current_layer.pop_front().unwrap_or(hash))
                            );
                    };

                current_layer = next_layer.span();
            };

        *current_layer.pop_front().unwrap()
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

        fn claim_128(
            ref self: ContractState, mut claims: Span<Claim>, remaining_proof: Span<felt252>
        ) -> u8 {
            assert(claims.len() < 129, 'TOO_MANY_CLAIMS');
            assert(!claims.is_empty(), 'CLAIMS_EMPTY');

            // groups that cross bitmap boundaries should just make multiple calls
            // this code already reduces the number of pedersens in the verification by a factor of ~7
            let (word, index_u64) = DivRem::div_rem(*claims.at(0).id, BITMAP_SIZE);
            assert(index_u64 == 0, 'FIRST_CLAIM_MUST_BE_MULT_128');

            let root_of_group = compute_root_of_group(claims);

            assert(
                self.root.read() == compute_pedersen_root(root_of_group, remaining_proof),
                'INVALID_PROOF'
            );

            let mut bitmap = self.claimed_bitmap.read(word);

            let mut index: u8 = 0;
            let mut unclaimed: Array<Claim> = ArrayTrait::new();

            while let Option::Some(claim) = claims
                .pop_front() {
                    let already_claimed = (bitmap & exp2(index)).is_non_zero();

                    if !already_claimed {
                        bitmap = bitmap | exp2(index);
                        unclaimed.append(*claim);
                    }

                    index += 1;
                };

            self.claimed_bitmap.write(word, bitmap);

            let num_claimed = unclaimed.len();

            // the event emittance and transfers are separated from the above to prevent re-entrance
            let token = self.token.read();

            while let Option::Some(claim) = unclaimed
                .pop_front() {
                    token.transfer(claim.claimee, claim.amount.into());
                    self.emit(Claimed { claim });
                };

            // never fails because we assert claims length at the beginning so we know it's less than 128
            num_claimed.try_into().unwrap()
        }

        fn is_claimed(self: @ContractState, claim_id: u64) -> bool {
            let (word, index) = claim_id_to_bitmap_index(claim_id);
            let bitmap = self.claimed_bitmap.read(word);
            (bitmap & exp2(index)).is_non_zero()
        }
    }
}
