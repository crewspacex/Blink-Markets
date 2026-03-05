# Blinkmarket Frontend API (Pyth)

This guide reflects the Pyth migration.

## Key Rules

- Crypto events use Pyth feed IDs (`oracle_feed_id`, 32 bytes).
- `target_price` must be USD fixed precision **1e8**.
- v1 feed scope: **SUI/USD only**.

## Event Creation (Crypto)

```ts
tx.moveCall({
  target: `${PACKAGE_ID}::blink_event::create_crypto_event`,
  typeArguments: [coinType],
  arguments: [
    tx.object(creatorCapId),
    tx.object(marketId),
    tx.pure.vector('u8', feedIdBytes32),
    tx.pure.u128(targetPrice1e8),
    tx.pure.u64(durationMs),
  ],
});
```

## Event Resolution (Admin/Keeper flow)

`resolve_crypto_event` now requires Pyth state and a Pyth `PriceInfoObject`:

```ts
tx.moveCall({
  target: `${PACKAGE_ID}::blink_event::resolve_crypto_event`,
  typeArguments: [coinType],
  arguments: [
    tx.object(eventId),
    tx.object(marketId),
    tx.object(PYTH_STATE_ID),
    tx.object(PYTH_PRICE_INFO_OBJECT_ID),
    tx.object('0x6'), // Clock
  ],
});
```

Normally your keeper should update Pyth first in the same PTB (via `SuiPythClient.updatePriceFeeds(...)`) and then call resolve.

## View Calls

- `get_event_type`
- `get_oracle_feed_id`
- `get_target_price` (1e8)
- `get_oracle_price_at_resolution` (1e8)
- `get_event_status`
- `get_odds`

## Frontend env alignment

If your frontend/admin tooling stores oracle config, use:

- `PYTH_PACKAGE_ID`
- `PYTH_STATE_ID`
- `WORMHOLE_STATE_ID`
- `PYTH_FEED_SUI_USD`
- `PYTH_HERMES_URL`

Avoid keeping old `STORK_*` env keys to prevent drift with keeper/backend.
