use cubit::f128::{Fixed, FixedTrait};

#[derive(Drop, Copy, Serde, starknet::Store)]
struct VRGDAParameters {
    // The price at which the VRGDA should aim to sell the tokens
    target_price: Fixed,
    // How many tokens should be sold per time unit, in combination with the target price determines the rate
    num_sold_per_time_unit: u64,
    // How the price decays per time unit, if none are sold
    price_decay_percent: Fixed,
}

#[generate_trait]
impl VRGDAParametersTraitImpl of VRGDAParametersTrait {
    fn decay_constant(self: VRGDAParameters) -> Fixed {
        (FixedTrait::ONE() - self.price_decay_percent).ln()
    }

    fn p_integral(self: VRGDAParameters, time_units_since_start: Fixed, sold: u64) -> Fixed {
        -(self.target_price
            * FixedTrait::new_unscaled(self.num_sold_per_time_unit.into(), false)
            * (FixedTrait::ONE() - self.price_decay_percent)
                .pow(
                    time_units_since_start
                        - (FixedTrait::new_unscaled(sold.into(), false)
                            / FixedTrait::new_unscaled(self.num_sold_per_time_unit.into(), false))
                )
            / self.decay_constant())
    }

    fn quote_batch(
        self: VRGDAParameters, time_units_since_start: Fixed, sold: u64, amount: u64
    ) -> Fixed {
        self.p_integral(time_units_since_start, sold + amount)
            - self.p_integral(time_units_since_start, sold)
    }

    fn p(self: VRGDAParameters, time_units_since_start: Fixed, sold: u64) -> Fixed {
        self.quote_batch(time_units_since_start, sold, amount: 1)
    }
}
