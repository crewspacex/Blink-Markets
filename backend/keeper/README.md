# Blinkmarket Keeper Service (Pyth)

Automated keeper service for resolving Blinkmarket crypto events using Pyth pull-oracle updates on Sui testnet.

## Flow

1. Poll pending crypto events (`STATUS_OPEN` + betting window ended).
2. Fetch update payload from Pyth Hermes for `PYTH_FEED_SUI_USD`.
3. Build one PTB:
   - `pyth::pyth::update_price_feeds` via `SuiPythClient.updatePriceFeeds(...)`
   - `blink_event::resolve_crypto_event(...)`
4. Submit PTB with oracle signer.
5. Emit metrics and release distributed lock.

## Required Environment

Use `.env.example` and set:

- `PACKAGE_ID`
- `MARKET_ID`
- `ORACLE_PRIVATE_KEY`
- `ORACLE_ADDRESS`
- `PYTH_PACKAGE_ID`
- `PYTH_STATE_ID`
- `WORMHOLE_STATE_ID`
- `PYTH_FEED_SUI_USD`

## Commands

```bash
npm install
npm run dev
npm run build
npm test
```

## Metrics

- `blinkmarket_events_resolved_total`
- `blinkmarket_oracle_api_calls_total`
- `blinkmarket_oracle_api_duration_seconds`
- `blinkmarket_resolution_errors_total`
- `blinkmarket_pending_events`
- `blinkmarket_active_locks`
- `blinkmarket_resolution_duration_seconds`
- `blinkmarket_gas_used`
