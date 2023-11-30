# Управление Ekubo

[![Tests](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml/badge.svg)](https://github.com/EkuboProtocol/governance/actions/workflows/test.yaml)

Простые контракты для токенизированного управления на Starknet.

## Принципы

Данные контракты следуют архитектуре управления проекта Compound.
Контракты не обнволяемы, так что проект разбит на модули и заменяемые компоненты.
Подразумевается, что все контракт обновляемы путем обычной миграции на новые версии.

Даже контракт токена может быть мигриован, если необходим, путем развертывания нового контракта, который позволяет сжечь старый токен и заминтить новый.

## Компоненты

- `Timelock` контракт с владельцем, который позволяет владельцу ставить на очередь список вызовов
    - Любой может совершать вызовы после промежутка времени, если владелец поставил их (вызовы) в очередь
    - Timelock обычно управляет всеми активами и редко обновляется
    - Чтобы обновить timelock, все активы должны быть перемещены на новый контракт timelock
- `Governor` контролирует голосование на вызове _single call_ , который можно добавить в timelock
    - Спроектирован так, чтобы быть владельцем Timelock
    - Одиночный вызов может быть постановкой в очередь вызовов `Timelock#queue(calls)`, которые, могут исполнять множество вызовов в одиночном предложении.
    - Владение Timelock может быть передано новому контракту управления в будущем, например, мигрировать на контракт голосования, основанный на volition.
    - Мета данные предложений не хранятся в governor, только лишь количество голосов
    - Предложения могут быть отменены в любой момент времени, если сила голоса предложившего упадет ниже минимального порогового значения
- `GovernanceToken` is an ERC20 token meant for voting in contracts like `Governor`
    - Users must delegate their tokens to vote, and may delegate to themselves
    - Allows other contracts to get the average voting weight for *any* historical period
    - Average votes are used to compute voting weight in the `Governor`, over a configurable period of time
- `Airdrop` can be used to distribute GovernanceToken
    - Compute a merkle root by computing a list of amounts and recipients, hashing them, and arranging them into a merkle binary tree
    - Deploy the airdrop with the root and the token address
    - Transfer the total amount of tokens to the `Airdrop` contract
- `Factory` allows creating the entire set of contracts with one call

## Testing

Make sure you have [Scarb with asdf](https://docs.swmansion.com/scarb/download#install-via-asdf) installed.

To run unit tests:

```
scarb test
```

## Disclaimer

These contracts are unaudited. Use at your own risk. Additional review is greatly appreciated.

## Credits

The [Airdrop](./src/airdrop.cairo) contract was heavily inspired by the [Carmine Options Airdrop contract](https://github.com/CarmineOptions/governance/blob/master/src/airdrop.cairo).
