# Bug bounty program

Any bug submitted to [security@ekubo.org](mailto:security@ekubo.org), found in the latest tagged release,
will receive a bug bounty of up to $10,000 USD paid from Ekubo, Inc.

## Procedure

The bounty is payable by USDC on the Starknet chain, or wire, to an address
submitted by email with the bug report. We will respond to any reported
vulnerability within 1 business day.

Multiple submissions of the same issue to the security email within 24 hours of each other period will split the bug bounty evenly.

Test code is not included in the bug bounty.

## Classification of issues

The tier of the bug and the reward for it is up to our discretion,
and a typical characterization of each tier is described below.

These are examples and bounties may be awarded for issues found that do not exactly match any description.

## High tier (up to $10k)

- Artificially manipulate, or change without authorization, any of:
  - delegated token amounts
  - staked amounts
  - average amounts delegated over a historical period
- Freeze the operation of Timelock or Governor
- Prevent execution of an approved call or set of calls in perpetuity (i.e. denial of service)
- Drain contract funds without authorization
- Incorrect hash functions (i.e. hash collisions)

## Medium/low tier (up to $5k)

All other issues.
