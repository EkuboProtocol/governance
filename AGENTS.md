# AGENTS.md

## Complexity Policy (Solidity, `l1_proxy/`)
- Cyclomatic complexity is capped at 7 per function. CI enforces it; run it locally from
  `l1_proxy/` with:
  `npx -y solhint@6.2.4 --disc --noPoster -c .solhint.json --max-warnings 0 'src/**/*.sol' 'script/**/*.sol' 'test/**/*.sol'`
- **Never** silence it with a `// solhint-disable` comment. The owner proxies are
  immutable and already deployed, and solc embeds a hash of the source in the metadata
  trailer — editing a `.sol` file at all, comments included, changes the bytecode and
  therefore the deploy address. Simplify or split the function instead.

## Complexity Policy (Cairo, `src/`)
- There is no complexity gate for Cairo. `scarb lint` (cairo-lint 2.20) ships only
  style and idiom rules — no cyclomatic or cognitive complexity rule and no threshold
  config. Nothing to enable here until upstream adds one.
