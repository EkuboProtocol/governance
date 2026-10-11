# AGENTS.md

## Complexity Policy (Solidity, `l1_proxy/`)
- Cyclomatic complexity is capped at 7 per function. Run `bun run lint` from
  `l1_proxy/`; CI runs the same command. solhint is pinned exactly in
  `l1_proxy/package.json`, so the version that runs is not whatever a registry hands
  back at the time.
- **Never** silence it with a `// solhint-disable` comment. The owner proxies are
  immutable and already deployed, and solc embeds a hash of the source in the metadata
  trailer — editing a `.sol` file at all, comments included, changes the bytecode and
  therefore the deploy address. Simplify or split the function instead.

## Complexity Policy (Cairo, `src/`)
- There is no complexity gate for Cairo. `scarb lint` (cairo-lint 2.20) ships only
  style and idiom rules — no cyclomatic or cognitive complexity rule and no threshold
  config. Nothing to enable here until upstream adds one.
