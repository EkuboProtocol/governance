use array::{Span, SpanTrait};
use hash::LegacyHash;
use traits::Into;

/// Compute the merkle root of a given proof.
/// # Arguments
/// * `current_node` - The current node of the proof.
/// * `proof` - The proof.
/// # Returns
/// The merkle root.
fn compute_root(mut current_node: felt252, mut proof: Span<felt252>) -> felt252 {
    loop {
        match proof.pop_front() {
            Option::Some(proof_element) => {
                // Compute the hash of the current node and the current element of the proof.
                // We need to check if the current node is smaller than the current element of the proof.
                // If it is, we need to swap the order of the hash.
                let a: u256 = current_node.into();
                let b: u256 = (*proof_element).into();
                if b > a {
                    current_node = LegacyHash::hash(current_node, *proof_element);
                } else {
                    current_node = LegacyHash::hash(*proof_element, current_node);
                }
            },
            Option::None(()) => {
                break current_node;
            },
        };
    }
}

/// Verify a merkle proof.
/// # Arguments
/// * `root` - The merkle root.
/// * `leaf` - The leaf to verify.
/// * `proof` - The proof.
/// # Returns
/// True if the proof is valid, false otherwise.
fn verify(root: felt252, leaf: felt252, mut proof: Span<felt252>) -> bool {
    compute_root(leaf, proof) == root
}
