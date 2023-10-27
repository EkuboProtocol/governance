use starknet::{ContractAddress};
use governance::vrgda::{VRGDAParameters, VRGDAParametersTrait};

#[starknet::interface]
trait ITokenVRGDA<TContractState> {
    // Buy the token with the ETH transferred to this contract, receiving at least min_amount_out
    // The result is transferred to the recipient
    fn buy(ref self: TContractState, buy_amount: u64, max_amount_in: u128) -> u128;

    // Withdraw the proceeds, must be called by the benefactor
    fn withdraw_proceeds(ref self: TContractState);
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
}

// The buyer must transfer this token to the VRGDA contract before calling buy
#[starknet::interface]
trait IOptionToken<TContractState> {
    fn burn(ref self: TContractState, amount: u128);
}

#[starknet::contract]
mod TokenVRGDA {
    use super::{
        ContractAddress, ITokenVRGDA, IERC20Dispatcher, IERC20DispatcherTrait,
        IOptionTokenDispatcher, IOptionTokenDispatcherTrait, VRGDAParameters, VRGDAParametersTrait
    };
    use cubit::f128::{Fixed, FixedTrait};
    use starknet::{get_caller_address, get_contract_address, contract_address_const};

    #[storage]
    struct Storage {
        // The token that is used to buy the token
        payment_token: IERC20Dispatcher,
        // The token that gives the user the right to purchase the sold token
        option_token: IOptionTokenDispatcher,
        // The token that is sold
        sold_token: IERC20Dispatcher,
        // the configuration of the vrgda
        vrgda_parameters: VRGDAParameters,
        // The address that receives the payment token from the sale of the tokens
        benefactor: ContractAddress,
        // The amount of tokens that have been used to purchase the sold token and have not been withdrawn
        // Used to compute how much was paid
        reserves: u128,
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
        option_token: IOptionTokenDispatcher,
        sold_token: IERC20Dispatcher,
        vrgda_parameters: VRGDAParameters,
        benefactor: ContractAddress
    ) {
        self.payment_token.write(payment_token);
        self.option_token.write(option_token);
        self.sold_token.write(sold_token);
        self.vrgda_parameters.write(vrgda_parameters);
        self.benefactor.write(benefactor);
    }

    #[external(v0)]
    impl TokenVRGDAImpl of ITokenVRGDA<ContractState> {
        fn buy(ref self: ContractState, buy_amount: u64, max_amount_in: u128) -> u128 {
            let payment_token = self.payment_token.read();
            let option_token = self.option_token.read();
            let sold_token = self.sold_token.read();

            let reserves = self.reserves.read();

            let payment_balance: u128 = payment_token
                .balanceOf(get_contract_address())
                .try_into()
                .expect('PAID_OVERFLOW');

            let paid: u128 = payment_balance - reserves;

            self.reserves.write(payment_balance);

            let amount_sold = self.amount_sold.read();

            let quote = self
                .vrgda_parameters
                .read()
                .quote_batch(
                    time_units_since_start: FixedTrait::new(0, false),
                    sold: amount_sold.try_into().unwrap(),
                    amount: buy_amount
                );
            let sold: u128 = 0;

            // assert(quote >= max_amount_in, 'PURCHASED');

            // Account for the newly sold amount before transferring anything
            self.amount_sold.write(amount_sold + sold);

            // assert(
            //     sold
            //         .into() <= (amount_sold.into()
            //             + option_token.balanceOf(get_contract_address())),
            //     'INSUFFICIENT_OPTION_TOKENS'
            // );

            self.emit(Buy { buyer: get_caller_address(), paid, sold });

            sold_token.transfer(get_caller_address(), sold.into());

            sold
        }

        fn withdraw_proceeds(ref self: ContractState) {
            let benefactor = self.benefactor.read();
            assert(get_caller_address() == benefactor, 'BENEFACTOR_ONLY');
            let reserves = self.reserves.read();
            self.reserves.write(0);
            self.payment_token.read().transfer(benefactor, reserves.into());
        }
    }
}

