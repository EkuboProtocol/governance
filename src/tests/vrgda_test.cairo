use cubit::f128::{Fixed, FixedTrait};
use governance::vrgda::{VRGDAParameters, VRGDAParametersTrait};
use debug::{PrintTrait};


#[test]
#[available_gas(30000000)]
fn test_decay_constant() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .decay_constant() == FixedTrait::new(12786309186476892720, true),
        'decay_constant'
    );
}

#[test]
#[available_gas(30000000)]
fn test_p_at_time_zero() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .p(
                time_units_since_start: FixedTrait::ZERO(), sold: 0
            ) == FixedTrait::new(0x17154754c6a1bf740, false),
        'p'
    );
}

#[test]
#[available_gas(30000000)]
fn test_p_at_time_one() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .p(
                time_units_since_start: FixedTrait::ONE(), sold: 0
            ) == FixedTrait::new(0xb8aa3aa6350dfba0, false),
        'p'
    );
}

#[test]
#[available_gas(30000000)]
fn test_p_time_one_more_sold_per_time_unit() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1000,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .p(
                time_units_since_start: FixedTrait::ONE(), sold: 0
            ) == FixedTrait::new(0x8009f8be9ba94b6f, false),
        'p'
    );
}

#[test]
#[available_gas(30000000)]
fn test_p_time_zero_many_sold() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1000,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .p(
                time_units_since_start: FixedTrait::ZERO(), sold: 1000
            ) == FixedTrait::new(0x20032fd0c57d40b42, false),
        'p'
    );
}

#[test]
#[available_gas(30000000)]
fn test_p_sold_on_schedule() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1000,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .p(
                time_units_since_start: FixedTrait::ZERO(), sold: 1000
            ) == FixedTrait::new(0x20032fd0c57d40b42, false),
        'p'
    );
}

#[test]
#[available_gas(30000000)]
fn test_quote_batch_sold_example_schedule() {
    assert(
        VRGDAParameters {
            target_price: FixedTrait::ONE(),
            num_sold_per_time_unit: 1000,
            price_decay_percent: FixedTrait::ONE() / FixedTrait::new_unscaled(2, false)
        }
            .quote_batch(
                time_units_since_start: FixedTrait::ZERO(), sold: 0, amount: 10
            ) == FixedTrait::new(185108235227361442154, false), // ~= 10.0347
        'p'
    );
}
