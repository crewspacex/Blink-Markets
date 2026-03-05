# Blinkmarket (Pyth Migration)

Blinkmarket is a Sui prediction market protocol with:
- Manual events (multi-outcome)
- Crypto events (oracle-driven binary Above/Below)

This branch fully migrates oracle resolution from **Stork** to **Pyth pull oracle**.

## Oracle Model (Pyth)

- Supported crypto feed in v1: **SUI/USD only**
- `oracle_feed_id`: 32-byte Pyth feed id (`vector<u8>`)
- `target_price`: USD fixed precision **1e8**
- `oracle_price_at_resolution`: normalized oracle price at **1e8**

Outcome semantics:
- `0 = Above` (`oracle_price >= target_price`)
- `1 = Below` (`oracle_price < target_price`)

## Contract Interface Changes

`blink_event::resolve_crypto_event` now accepts Pyth objects:

```move
public fun resolve_crypto_event<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    market: &Market,
    pyth_state: &pyth::state::State,
    pyth_price_info_object: &pyth::price_info::PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

The function:
1. checks oracle auth and event state
2. locks `OPEN -> LOCKED`
3. verifies `PriceInfoObject` feed matches `oracle_feed_id`
4. reads latest Pyth price
5. normalizes to `1e8`
6. resolves and settles pools

`resolve_crypto_event_for_testing` remains available for deterministic tests.

## Keeper (backend/keeper)

Keeper uses Hermes + `@pythnetwork/pyth-sui-js` and builds one atomic PTB:
1. update Pyth feed on-chain
2. call `resolve_crypto_event`

### Keeper env (required)

- `PACKAGE_ID`
- `MARKET_ID`
- `ORACLE_PRIVATE_KEY`
- `ORACLE_ADDRESS`
- `PYTH_PACKAGE_ID`
- `PYTH_STATE_ID`
- `WORMHOLE_STATE_ID`
- `PYTH_HERMES_URL` (default `https://hermes.pyth.network`)
- `PYTH_FEED_SUI_USD`

See `backend/keeper/.env.example`.

## Testnet Notes

This repo targets **Sui testnet** for oracle automation.  
Use official Pyth Sui addresses/feed IDs from Pyth docs and keep them aligned with your env.
