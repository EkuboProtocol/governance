# Vendored Chainlink CCIP 2.0.0 (interfaces only)

Unmodified copies of five MIT-licensed files from the npm package
`@chainlink/contracts-ccip@2.0.0` (git tag `contracts-ccip-v2.0.0`, commit
`c2c125c27f056db2e98d21501922b6eff5750f36`).

- Tarball: https://registry.npmjs.org/@chainlink/contracts-ccip/-/contracts-ccip-2.0.0.tgz
- npm integrity: `sha512-P0KvQtZSYC1LevMSS16jOOSsqZG4g0n/MJdcWGmE0Z5U01NVYd1MnTQJOBPsbu1NWR79DBXPXLvyr9tR5y+tiw==` (verified)
- Tarball sha256: `59c3ea7be405d68cadd948ac1c8ee5e0b7df4d1cdcde709bf1515e009d5dd759`
- Source paths: `contracts/libraries/Client.sol`, `contracts/interfaces/{IAny2EVMMessageReceiver,IAny2EVMMessageReceiverV2,IRouterClient,IRouter}.sol`

Do not use `2.1.0-beta.*`. `IAny2EVMMessageReceiverV2` is vendored only so tests can prove the executor does
**not** advertise it. `CCIPReceiver` is intentionally not vendored or inherited.

File sha256 (`sha256sum libraries/*.sol interfaces/*.sol`):

```
9a8b02a4cf05f2a6a75287fb37f3a271404ccb477af0da001ac7b93835ad39cd  libraries/Client.sol
a2e161a2c241a5e0a1807bdf908d47eb8527f349bc2f56c6fbcc6bcf2c3ba4c2  interfaces/IAny2EVMMessageReceiver.sol
c88f880ca2f90f587683f703d9fb927380c95ec812962d6a907b1298c946ada6  interfaces/IAny2EVMMessageReceiverV2.sol
05fc882e5af0dfc2840d99ed887b5c405cf555525cc8d1329787dac369dff1e3  interfaces/IRouterClient.sol
8587799ce065559b3d8453f8debda485bf6049aaa59133662027f27200fa4bfe  interfaces/IRouter.sol
```
