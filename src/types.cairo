use starknet::{ContractAddress, ContractAddressIntoFelt252};
use array::{ArrayTrait, SpanTrait};
use traits::{Into};
use hash::{LegacyHash};

#[derive(Drop, Serde)]
struct Call {
    address: ContractAddress,
    entry_point_selector: felt252,
    calldata: Array<felt252>,
}

#[generate_trait]
impl CallTraitImpl of CallTrait {
    fn hash(self: @Call) -> felt252 {
        let mut data_hash = 0;
        let mut data_span = self.calldata.span();
        loop {
            match data_span.pop_front() {
                Option::Some(word) => {
                    data_hash = pedersen(data_hash, *word);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        pedersen(pedersen((*self.address).into(), *self.entry_point_selector), data_hash)
    }
}

