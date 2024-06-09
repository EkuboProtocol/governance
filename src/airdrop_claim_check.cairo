use governance::airdrop::IAirdropDispatcher;
use starknet::ContractAddress;

#[derive(Serde, Copy, Drop)]
struct CheckParams {
    airdrop: IAirdropDispatcher,
    claim_id: u64,
    amount: u128,
}

#[derive(Serde, Copy, Drop)]
struct CheckResult {
    claimed: bool,
    funded: bool,
}

#[starknet::interface]
trait IAirdropClaimCheck<TContractState> {
    fn check(self: @TContractState, claims: Span<CheckParams>) -> Span<CheckResult>;
}

#[starknet::contract]
mod AirdropClaimCheck {
    use governance::airdrop::IAirdropDispatcherTrait;
    use governance::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{IAirdropClaimCheck, IAirdropDispatcher, CheckParams, CheckResult};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl AirdropClaimCheckImpl of IAirdropClaimCheck<ContractState> {
        fn check(self: @ContractState, mut claims: Span<CheckParams>) -> Span<CheckResult> {
            let mut result: Array<CheckResult> = array![];

            while let Option::Some(claim_check) = claims
                .pop_front() {
                    let token = IERC20Dispatcher {
                        contract_address: (*claim_check.airdrop).get_token()
                    };
                    let claimed = (*claim_check.airdrop).is_claimed(*claim_check.claim_id);
                    let funded = token
                        .balanceOf(
                            *claim_check.airdrop.contract_address
                        ) >= ((*claim_check.amount).into());
                    result.append(CheckResult { claimed, funded });
                };

            result.span()
        }
    }
}
