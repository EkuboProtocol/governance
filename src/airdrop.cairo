use starknet::ContractAddress;
use array::{Array};

#[starknet::interface]
trait IAirdrop<TStorage> {
    fn claim(ref self: TStorage, claimee: ContractAddress, amount: u128, proof: Array::<felt252>);
}

#[starknet::contract]
mod Airdrop {
    use super::{IAirdrop, ContractAddress};

    use array::ArrayTrait;
    use hash::LegacyHash;
    use traits::{Into, TryInto};
    use starknet::ContractAddressIntoFelt252;

    use governance::merkle_tree::{verify};
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};

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
            let amount_felt: felt252 = amount.into();
            let leaf = LegacyHash::hash(claimee.into(), amount_felt);
            assert(!self.claimed.read(leaf), 'ALREADY_CLAIMED');
            assert(verify(self.root.read(), leaf, proof.span()), 'INVALID_PROOF');
            self.claimed.write(leaf, true);

            self.token.read().transfer(claimee, u256 { high: 0, low: amount });

            self.emit(Event::Claimed(Claimed { claimee, amount }));
        }
    }
}
