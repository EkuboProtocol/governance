use starknet::{ContractAddress};

#[starknet::interface]
trait IVRGDA<TContractState> {
    // Buy the token with the ETH transferred to this contract, receiving at least min_amount_out
    // The result is transferred to the recipient
    fn buy(ref self: TContractState, min_amount_out: u128) -> u128;

    // Refund any payment token that is still held by the contract
    fn clear_payment(ref self: TContractState) -> u256;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct SaleConfig {
    // When the sales should begin, in epoch seconds
    start_time: u64,
    // How long the sale will last, in seconds
    duration: u64,
    // A 64 bit number indicating the number of tokens that should be sold per second
    // The token is assumed to have 18 decimals, so this number is not a fractional quantity, i.e. 1 represents 1e-18 tokens per second
    sell_rate: u64,
}

#[starknet::contract]
mod VRGDA {
    use super::{SaleConfig, ContractAddress, IVRGDA, IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{get_caller_address, get_contract_address, contract_address_const};

    #[storage]
    struct Storage {
        // The token that is used to buy the token
        payment_token: IERC20Dispatcher,
        // The token that gives the user the right to purchase the sold token
        option_token: IERC20Dispatcher,
        // The token that is sold
        sold_token: IERC20Dispatcher,
        // the configuration of the sale
        sale_config: SaleConfig,
        // The address that receives the payment token from the sale of the tokens
        benefactor: ContractAddress,
        // The number of sold tokens thus far
        amount_sold: u128,
    }

    #[derive(starknet::Event, Drop)]
    struct Buy {
        buyer: ContractAddress,
        paid: u128,
        sold: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        Buy: Buy,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        payment_token: IERC20Dispatcher,
        option_token: IERC20Dispatcher,
        sold_token: IERC20Dispatcher,
        sale_config: SaleConfig,
        benefactor: ContractAddress
    ) {
        self.payment_token.write(payment_token);
        self.option_token.write(option_token);
        self.sold_token.write(sold_token);
        self.sale_config.write(sale_config);
        self.benefactor.write(benefactor);
    }

    #[external(v0)]
    impl VRGDAImpl of IVRGDA<ContractState> {
        fn buy(ref self: ContractState, min_amount_out: u128) -> u128 {
            let pt = self.payment_token.read();
            let ot = self.option_token.read();
            let st = self.sold_token.read();
            let paid: u128 = pt
                .balanceOf(get_contract_address())
                .try_into()
                .expect('PAID_OVERFLOW');

            let amount_sold = self.amount_sold.read();

            // todo: compute the amount sold based on current time, the sales config, and the amount sold thus far
            let sold: u128 = 0;

            assert(sold >= min_amount_out, 'PURCHASED');

            // Account for the newly sold amount before transferring anything
            self.amount_sold.write(amount_sold + sold);

            assert(
                sold.into() <= (amount_sold.into() + ot.balanceOf(get_contract_address())),
                'INSUFFICIENT_OPTIONS'
            );

            self.emit(Buy { buyer: get_caller_address(), paid, sold });

            st.transfer(get_caller_address(), sold.into());

            sold
        }

        fn clear_payment(ref self: ContractState) -> u256 {
            let pt = self.payment_token.read();
            let refund = pt.balanceOf(get_contract_address());
            pt.transfer(get_caller_address(), refund);
            refund
        }
    }
}

