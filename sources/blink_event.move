/// Module: blink_event
/// Event lifecycle management and oracle operations for prediction markets
module blinkmarket::blink_event;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::event;

use blinkmarket::blink_config::{Self, MarketCreatorCap, Market};

// Pyth oracle imports
use pyth::pyth;
use pyth::state::State as PythState;
use pyth::price_info::{Self as pyth_price_info, PriceInfoObject};
use pyth::price;
use pyth::price_identifier;
use pyth::i64 as pyth_i64;

// ============== Error Constants ==============

// Authorization errors
const ENotOracle: u64 = 1;

// State errors
const EEventNotOpen: u64 = 101;
const EEventNotResolved: u64 = 103;
const EEventNotCancelled: u64 = 104;

// Validation errors
const EInvalidOutcome: u64 = 200;
const ETooFewOutcomes: u64 = 205;
const ETooManyOutcomes: u64 = 206;
const EEventMismatch: u64 = 207;
const ENotCryptoEvent: u64 = 208;
const ENotManualEvent: u64 = 209;
const EInvalidFeedId: u64 = 210;
const ETargetPriceZero: u64 = 211;
const ENegativeOraclePrice: u64 = 212;

// Timing errors
const EBettingNotStarted: u64 = 300;
const EBettingClosed: u64 = 301;

// Event status constants
const STATUS_CREATED: u8 = 0;
const STATUS_OPEN: u8 = 1;
const STATUS_LOCKED: u8 = 2;
const STATUS_RESOLVED: u8 = 3;
const STATUS_CANCELLED: u8 = 4;

// Event type constants
const EVENT_TYPE_CRYPTO: u8 = 0;
const EVENT_TYPE_MANUAL: u8 = 1;

// Configuration constants
const MIN_OUTCOMES: u64 = 2;
const MAX_OUTCOMES: u64 = 10;
const BPS_DENOMINATOR: u64 = 10000;
const FEED_ID_LENGTH: u64 = 32;
const ORACLE_TARGET_DECIMALS: u64 = 8;

/// Get BPS denominator (package-internal helper)
public(package) fun get_bps_denominator(): u64 {
    BPS_DENOMINATOR
}

// ============== Core Structs ==============

/// Individual prediction event with outcome pools (generic over coin type)
public struct PredictionEvent<phantom CoinType> has key, store {
    id: UID,
    market_id: ID,
    description: vector<u8>,
    outcome_labels: vector<vector<u8>>,
    outcome_pools: vector<Balance<CoinType>>,
    total_pool: u64,
    status: u8,
    betting_start_time: u64,
    betting_end_time: u64,
    duration: u64,
    winning_outcome: u8,
    creator: address,
    resolved_at: u64,
    winning_pool_at_resolution: u64,
    // Oracle integration fields
    event_type: u8,                    // EVENT_TYPE_CRYPTO or EVENT_TYPE_MANUAL
    oracle_feed_id: vector<u8>,        // 32-byte Pyth feed ID (empty for manual)
    target_price: u128,                // Target price threshold (USD 1e8 precision, 0 for manual)
    oracle_price_at_resolution: u128,  // Actual oracle price at resolution (0 for manual)
}

// ============== Events ==============

public struct EventCreated has copy, drop {
    event_id: ID,
    market_id: ID,
    description: vector<u8>,
    num_outcomes: u64,
    event_type: u8,
    oracle_feed_id: vector<u8>,
    target_price: u128,
}

public struct EventResolved has copy, drop {
    event_id: ID,
    winning_outcome: u8,
    total_pool: u64,
    event_type: u8,
    oracle_price: u128,
}

// ============== Event Creation ==============

/// Create a new crypto prediction event (binary: above/below target price, USD 1e8 precision)
public fun create_crypto_event<CoinType>(
    creator_cap: &MarketCreatorCap,
    market: &Market,
    description: vector<u8>,
    oracle_feed_id: vector<u8>,
    target_price: u128,
    duration: u64,
    ctx: &mut TxContext,
) {
    blink_config::assert_market_active(market);
    blink_config::assert_market_id_matches(
        market,
        blink_config::get_creator_cap_market_id(creator_cap)
    );

    // Validate feed ID is 32 bytes
    assert!(oracle_feed_id.length() == FEED_ID_LENGTH, EInvalidFeedId);

    // Validate target price is nonzero
    assert!(target_price > 0, ETargetPriceZero);

    // Crypto events are always binary: outcome 0 = "Above", outcome 1 = "Below"
    let outcome_labels = vector[b"Above", b"Below"];
    let num_outcomes = 2u64;

    // Initialize outcome pools
    let mut outcome_pools = vector::empty<Balance<CoinType>>();
    let mut i = 0;
    while (i < num_outcomes) {
        outcome_pools.push_back(balance::zero<CoinType>());
        i = i + 1;
    };

    let prediction_event = PredictionEvent<CoinType> {
        id: object::new(ctx),
        market_id: object::id(market),
        description,
        outcome_labels,
        outcome_pools,
        total_pool: 0,
        status: STATUS_CREATED,
        betting_start_time: 0,
        betting_end_time: 0,
        duration,
        winning_outcome: 0,
        creator: tx_context::sender(ctx),
        resolved_at: 0,
        winning_pool_at_resolution: 0,
        event_type: EVENT_TYPE_CRYPTO,
        oracle_feed_id,
        target_price,
        oracle_price_at_resolution: 0,
    };

    event::emit(EventCreated {
        event_id: object::id(&prediction_event),
        market_id: object::id(market),
        description: prediction_event.description,
        num_outcomes,
        event_type: EVENT_TYPE_CRYPTO,
        oracle_feed_id: prediction_event.oracle_feed_id,
        target_price,
    });

    transfer::share_object(prediction_event);
}

/// Create a new manual prediction event (for sports, custom markets, etc.)
public fun create_manual_event<CoinType>(
    creator_cap: &MarketCreatorCap,
    market: &Market,
    description: vector<u8>,
    outcome_labels: vector<vector<u8>>,
    duration: u64,
    ctx: &mut TxContext,
) {
    blink_config::assert_market_active(market);
    blink_config::assert_market_id_matches(
        market,
        blink_config::get_creator_cap_market_id(creator_cap)
    );

    let num_outcomes = outcome_labels.length();
    assert!(num_outcomes >= MIN_OUTCOMES, ETooFewOutcomes);
    assert!(num_outcomes <= MAX_OUTCOMES, ETooManyOutcomes);

    // Initialize outcome pools
    let mut outcome_pools = vector::empty<Balance<CoinType>>();
    let mut i = 0;
    while (i < num_outcomes) {
        outcome_pools.push_back(balance::zero<CoinType>());
        i = i + 1;
    };

    let prediction_event = PredictionEvent<CoinType> {
        id: object::new(ctx),
        market_id: object::id(market),
        description,
        outcome_labels,
        outcome_pools,
        total_pool: 0,
        status: STATUS_CREATED,
        betting_start_time: 0,
        betting_end_time: 0,
        duration,
        winning_outcome: 0,
        creator: tx_context::sender(ctx),
        resolved_at: 0,
        winning_pool_at_resolution: 0,
        event_type: EVENT_TYPE_MANUAL,
        oracle_feed_id: vector::empty<u8>(),
        target_price: 0,
        oracle_price_at_resolution: 0,
    };

    event::emit(EventCreated {
        event_id: object::id(&prediction_event),
        market_id: object::id(market),
        description: prediction_event.description,
        num_outcomes,
        event_type: EVENT_TYPE_MANUAL,
        oracle_feed_id: vector::empty<u8>(),
        target_price: 0,
    });

    transfer::share_object(prediction_event);
}

// ============== Event Lifecycle ==============

/// Open an event for betting
public fun open_event<CoinType>(
    creator_cap: &MarketCreatorCap,
    prediction_event: &mut PredictionEvent<CoinType>,
    clock: &Clock,
) {
    let start = clock::timestamp_ms(clock);
    assert!(
        prediction_event.market_id == blink_config::get_creator_cap_market_id(creator_cap),
        EEventMismatch
    );
    assert!(prediction_event.status == STATUS_CREATED, EEventNotOpen);
    prediction_event.betting_start_time = start;
    prediction_event.betting_end_time = start + prediction_event.duration;
    prediction_event.status = STATUS_OPEN;
}

/// Cancel an event (enables refunds). Only from CREATED or OPEN state.
public fun cancel_event<CoinType>(
    creator_cap: &MarketCreatorCap,
    prediction_event: &mut PredictionEvent<CoinType>,
) {
    assert!(
        prediction_event.market_id == blink_config::get_creator_cap_market_id(creator_cap),
        EEventMismatch
    );
    assert!(
        prediction_event.status == STATUS_CREATED ||
        prediction_event.status == STATUS_OPEN,
        EEventNotOpen
    );
    prediction_event.status = STATUS_CANCELLED;
}

// ============== Resolution ==============

/// Resolve a crypto event using Pyth oracle price feed.
/// Keeper should update the Pyth feed in the same PTB before calling this.
///
/// Execution order optimized for minimal timing drift and gas waste:
/// 1. Cheap validations (authorization, status, timing)
/// 2. Atomic lock (OPEN → LOCKED)
/// 3. Read oracle price (time-sensitive)
/// 4. Determine winner (above/below target)
/// 5. Execute settlement (merge pools)
public fun resolve_crypto_event<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    market: &Market,
    pyth_state: &PythState,
    pyth_price_info_object: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // === Step 1: Cheap validations ===

    // Validate caller is authorized oracle
    let sender = tx_context::sender(ctx);
    assert!(blink_config::is_oracle(market, sender), ENotOracle);

    // Validate event belongs to this market
    assert!(prediction_event.market_id == object::id(market), EEventMismatch);

    // Validate this is a crypto event
    assert!(prediction_event.event_type == EVENT_TYPE_CRYPTO, ENotCryptoEvent);

    // Event must be OPEN and betting time must have ended
    let current_time = clock::timestamp_ms(clock);
    assert!(
        prediction_event.status == STATUS_OPEN && current_time >= prediction_event.betting_end_time,
        EEventNotOpen
    );

    // === Step 2: Atomic lock ===
    prediction_event.status = STATUS_LOCKED;

    // === Step 3: Read oracle price (time-sensitive — minimize delay) ===

    // Ensure the provided PriceInfoObject matches the event feed.
    let price_info = pyth_price_info::get_price_info_from_price_info_object(pyth_price_info_object);
    let price_identifier = pyth_price_info::get_price_identifier(&price_info);
    let feed_id_bytes = price_identifier::get_bytes(&price_identifier);
    assert!(feed_id_bytes == prediction_event.oracle_feed_id, EInvalidFeedId);

    let latest_price = pyth::get_price(
        pyth_state,
        pyth_price_info_object,
        clock,
    );
    let raw_price = price::get_price(&latest_price);

    // For crypto, price should always be positive
    assert!(!pyth_i64::get_is_negative(&raw_price), ENegativeOraclePrice);
    let raw_price_magnitude = pyth_i64::get_magnitude_if_positive(&raw_price);
    let raw_expo = price::get_expo(&latest_price);
    let oracle_price = normalize_price_to_target_decimals(raw_price_magnitude, raw_expo);

    // Store the oracle price for auditability
    prediction_event.oracle_price_at_resolution = oracle_price;

    // === Step 4: Determine winner ===
    // Outcome 0 = "Above" (price >= target_price)
    // Outcome 1 = "Below" (price < target_price)
    let winning_outcome: u8 = if (oracle_price >= prediction_event.target_price) {
        0 // Above
    } else {
        1 // Below
    };

    // === Step 5: Execute settlement ===
    prediction_event.winning_outcome = winning_outcome;
    prediction_event.status = STATUS_RESOLVED;
    prediction_event.resolved_at = clock::timestamp_ms(clock);

    // Record the winning pool balance before merging losing pools
    let winning_idx = winning_outcome as u64;
    prediction_event.winning_pool_at_resolution = balance::value(
        &prediction_event.outcome_pools[winning_idx]
    );

    // Join all losing outcome pools into the winning pool
    let num_outcomes = prediction_event.outcome_labels.length();
    let mut i = 0;
    while (i < num_outcomes) {
        if (i != winning_idx) {
            let losing_balance = balance::withdraw_all(
                &mut prediction_event.outcome_pools[i]
            );
            balance::join(
                &mut prediction_event.outcome_pools[winning_idx],
                losing_balance,
            );
        };
        i = i + 1;
    };

    event::emit(EventResolved {
        event_id: object::id(prediction_event),
        winning_outcome,
        total_pool: prediction_event.total_pool,
        event_type: EVENT_TYPE_CRYPTO,
        oracle_price,
    });
}

fun normalize_price_to_target_decimals(raw_price: u64, expo: pyth_i64::I64): u128 {
    let target_decimals = ORACLE_TARGET_DECIMALS;
    if (pyth_i64::get_is_negative(&expo)) {
        let current_decimals = pyth_i64::get_magnitude_if_negative(&expo);
        if (current_decimals == target_decimals) {
            return raw_price as u128
        };
        if (current_decimals > target_decimals) {
            let divisor = pow10_u128(current_decimals - target_decimals);
            return (raw_price as u128) / divisor
        };

        let multiplier = pow10_u128(target_decimals - current_decimals);
        return (raw_price as u128) * multiplier
    };

    let positive_expo = pyth_i64::get_magnitude_if_positive(&expo);
    let multiplier = pow10_u128(positive_expo + target_decimals);
    (raw_price as u128) * multiplier
}

fun pow10_u128(exp: u64): u128 {
    let mut result = 1u128;
    let mut i = 0;
    while (i < exp) {
        result = result * 10;
        i = i + 1;
    };
    result
}

/// Resolve a manual event with a manually-specified winning outcome (oracle only).
/// Used for sports, custom markets where outcome is determined off-chain.
public fun resolve_manual_event<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    market: &Market,
    winning_outcome: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate caller is authorized oracle
    let sender = tx_context::sender(ctx);
    assert!(blink_config::is_oracle(market, sender), ENotOracle);

    // Validate event state
    assert!(prediction_event.market_id == object::id(market), EEventMismatch);

    // Validate this is a manual event
    assert!(prediction_event.event_type == EVENT_TYPE_MANUAL, ENotManualEvent);

    // Event must be OPEN and betting time must have ended
    let current_time = clock::timestamp_ms(clock);
    assert!(
        prediction_event.status == STATUS_OPEN && current_time >= prediction_event.betting_end_time,
        EEventNotOpen
    );

    // Atomic lock
    prediction_event.status = STATUS_LOCKED;

    // Validate winning outcome
    let num_outcomes = prediction_event.outcome_labels.length();
    assert!((winning_outcome as u64) < num_outcomes, EInvalidOutcome);

    // Set resolution
    prediction_event.winning_outcome = winning_outcome;
    prediction_event.status = STATUS_RESOLVED;
    prediction_event.resolved_at = clock::timestamp_ms(clock);

    // Record the winning pool balance before merging losing pools
    let winning_idx = winning_outcome as u64;
    prediction_event.winning_pool_at_resolution = balance::value(
        &prediction_event.outcome_pools[winning_idx]
    );

    // Join all losing outcome pools into the winning pool
    let mut i = 0;
    while (i < num_outcomes) {
        if (i != winning_idx) {
            let losing_balance = balance::withdraw_all(
                &mut prediction_event.outcome_pools[i]
            );
            balance::join(
                &mut prediction_event.outcome_pools[winning_idx],
                losing_balance,
            );
        };
        i = i + 1;
    };

    event::emit(EventResolved {
        event_id: object::id(prediction_event),
        winning_outcome,
        total_pool: prediction_event.total_pool,
        event_type: EVENT_TYPE_MANUAL,
        oracle_price: 0,
    });
}

// ============== Package-internal Pool Access ==============

/// Add stake to outcome pool (called by blink_position)
public(package) fun add_to_pool<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    outcome_index: u8,
    stake_balance: Balance<CoinType>,
    net_stake: u64,
) {
    let pool = &mut prediction_event.outcome_pools[outcome_index as u64];
    balance::join(pool, stake_balance);
    prediction_event.total_pool = prediction_event.total_pool + net_stake;
}

/// Remove stake from outcome pool (called by blink_position for cancellations)
public(package) fun remove_from_pool<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    outcome_index: u8,
    amount: u64,
): Balance<CoinType> {
    let pool = &mut prediction_event.outcome_pools[outcome_index as u64];
    let withdrawn = balance::split(pool, amount);
    prediction_event.total_pool = prediction_event.total_pool - amount;
    withdrawn
}

/// Withdraw payout from the winning pool (called by blink_position for claims)
public(package) fun withdraw_payout<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    payout_amount: u64,
): Balance<CoinType> {
    let winning_idx = prediction_event.winning_outcome as u64;
    let winning_pool = &mut prediction_event.outcome_pools[winning_idx];
    balance::split(winning_pool, payout_amount)
}

// ============== Validation Helpers (package-internal) ==============

/// Validate event is open for betting
public(package) fun assert_event_open<CoinType>(prediction_event: &PredictionEvent<CoinType>) {
    assert!(prediction_event.status == STATUS_OPEN, EEventNotOpen);
}

/// Validate event timing
public(package) fun assert_betting_time_valid<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
    clock: &Clock,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= prediction_event.betting_start_time, EBettingNotStarted);
    assert!(current_time < prediction_event.betting_end_time, EBettingClosed);
}

/// Validate outcome index
public(package) fun assert_valid_outcome<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
    outcome_index: u8,
) {
    let num_outcomes = prediction_event.outcome_labels.length();
    assert!((outcome_index as u64) < num_outcomes, EInvalidOutcome);
}

/// Validate event is resolved
public(package) fun assert_event_resolved<CoinType>(prediction_event: &PredictionEvent<CoinType>) {
    assert!(prediction_event.status == STATUS_RESOLVED, EEventNotResolved);
}

/// Validate event is cancelled
public(package) fun assert_event_cancelled<CoinType>(prediction_event: &PredictionEvent<CoinType>) {
    assert!(prediction_event.status == STATUS_CANCELLED, EEventNotCancelled);
}

/// Check if outcome is the winning outcome
public(package) fun is_winning_outcome<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
    outcome_index: u8,
): bool {
    prediction_event.winning_outcome == outcome_index
}

/// Get market ID from event
public(package) fun get_event_market_id<CoinType>(prediction_event: &PredictionEvent<CoinType>): ID {
    prediction_event.market_id
}

/// Get winning pool balance
public(package) fun get_winning_pool_balance<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
    outcome_index: u8,
): u64 {
    balance::value(&prediction_event.outcome_pools[outcome_index as u64])
}

/// Get the winning pool balance recorded at resolution time (before merge)
public(package) fun get_winning_pool_at_resolution<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
): u64 {
    prediction_event.winning_pool_at_resolution
}

/// Get total pool amount
public(package) fun get_total_pool_amount<CoinType>(prediction_event: &PredictionEvent<CoinType>): u64 {
    prediction_event.total_pool
}

// ============== View Functions ==============

/// Get current odds for all outcomes (returns pool balances)
public fun get_odds<CoinType>(prediction_event: &PredictionEvent<CoinType>): vector<u64> {
    let mut odds = vector::empty<u64>();
    let num_outcomes = prediction_event.outcome_pools.length();
    let mut i = 0;
    while (i < num_outcomes) {
        odds.push_back(balance::value(&prediction_event.outcome_pools[i]));
        i = i + 1;
    };
    odds
}

/// Calculate potential payout for a given stake on an outcome
public fun calculate_potential_payout<CoinType>(
    prediction_event: &PredictionEvent<CoinType>,
    outcome_index: u8,
    stake_amount: u64,
): u64 {
    let num_outcomes = prediction_event.outcome_labels.length();
    assert!((outcome_index as u64) < num_outcomes, EInvalidOutcome);

    let outcome_pool = balance::value(&prediction_event.outcome_pools[outcome_index as u64]);
    let total_pool = prediction_event.total_pool;

    // If no one has bet yet, return the stake (1:1)
    if (outcome_pool == 0) {
        return stake_amount
    };

    // New pool after this bet
    let new_outcome_pool = outcome_pool + stake_amount;
    let new_total_pool = total_pool + stake_amount;

    // Potential payout: (stake / new_outcome_pool) * new_total_pool
    // Use u128 to avoid overflow
    let numerator = (stake_amount as u128) * (new_total_pool as u128);
    (numerator / (new_outcome_pool as u128)) as u64
}

/// Check if betting is currently open
public fun is_betting_open<CoinType>(prediction_event: &PredictionEvent<CoinType>, clock: &Clock): bool {
    if (prediction_event.status != STATUS_OPEN) {
        return false
    };
    let current_time = clock::timestamp_ms(clock);
    current_time >= prediction_event.betting_start_time &&
    current_time < prediction_event.betting_end_time
}

/// Get event status
public fun get_event_status<CoinType>(prediction_event: &PredictionEvent<CoinType>): u8 {
    prediction_event.status
}

/// Get total pool amount
public fun get_total_pool<CoinType>(prediction_event: &PredictionEvent<CoinType>): u64 {
    prediction_event.total_pool
}

/// Get winning outcome (only valid after resolution)
public fun get_winning_outcome<CoinType>(prediction_event: &PredictionEvent<CoinType>): u8 {
    assert!(prediction_event.status == STATUS_RESOLVED, EEventNotResolved);
    prediction_event.winning_outcome
}

/// Get resolution timestamp (only valid after resolution)
public fun get_resolved_at<CoinType>(prediction_event: &PredictionEvent<CoinType>): u64 {
    assert!(prediction_event.status == STATUS_RESOLVED, EEventNotResolved);
    prediction_event.resolved_at
}

/// Get event type
public fun get_event_type<CoinType>(prediction_event: &PredictionEvent<CoinType>): u8 {
    prediction_event.event_type
}

/// Get oracle feed ID
public fun get_oracle_feed_id<CoinType>(prediction_event: &PredictionEvent<CoinType>): vector<u8> {
    prediction_event.oracle_feed_id
}

/// Get target price
public fun get_target_price<CoinType>(prediction_event: &PredictionEvent<CoinType>): u128 {
    prediction_event.target_price
}

/// Get oracle price at resolution
public fun get_oracle_price_at_resolution<CoinType>(prediction_event: &PredictionEvent<CoinType>): u128 {
    prediction_event.oracle_price_at_resolution
}

// ============== Test-only Functions ==============

#[test_only]
public fun get_status_created(): u8 { STATUS_CREATED }

#[test_only]
public fun get_status_open(): u8 { STATUS_OPEN }

#[test_only]
public fun get_status_locked(): u8 { STATUS_LOCKED }

#[test_only]
public fun get_status_resolved(): u8 { STATUS_RESOLVED }

#[test_only]
public fun get_status_cancelled(): u8 { STATUS_CANCELLED }

#[test_only]
public fun get_event_type_crypto(): u8 { EVENT_TYPE_CRYPTO }

#[test_only]
public fun get_event_type_manual(): u8 { EVENT_TYPE_MANUAL }

/// Test-only resolve for crypto events — accepts oracle_price directly,
/// bypassing Pyth oracle read. Used for unit testing.
#[test_only]
public fun resolve_crypto_event_for_testing<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    market: &Market,
    oracle_price: u128,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate caller is authorized oracle
    let sender = tx_context::sender(ctx);
    assert!(blink_config::is_oracle(market, sender), ENotOracle);

    // Validate event
    assert!(prediction_event.market_id == object::id(market), EEventMismatch);
    assert!(prediction_event.event_type == EVENT_TYPE_CRYPTO, ENotCryptoEvent);

    let current_time = clock::timestamp_ms(clock);
    assert!(
        prediction_event.status == STATUS_OPEN && current_time >= prediction_event.betting_end_time,
        EEventNotOpen
    );

    // Atomic lock
    prediction_event.status = STATUS_LOCKED;

    // Store oracle price
    prediction_event.oracle_price_at_resolution = oracle_price;

    // Determine winner
    let winning_outcome: u8 = if (oracle_price >= prediction_event.target_price) {
        0 // Above
    } else {
        1 // Below
    };

    // Execute settlement
    prediction_event.winning_outcome = winning_outcome;
    prediction_event.status = STATUS_RESOLVED;
    prediction_event.resolved_at = clock::timestamp_ms(clock);

    let winning_idx = winning_outcome as u64;
    prediction_event.winning_pool_at_resolution = balance::value(
        &prediction_event.outcome_pools[winning_idx]
    );

    let num_outcomes = prediction_event.outcome_labels.length();
    let mut i = 0;
    while (i < num_outcomes) {
        if (i != winning_idx) {
            let losing_balance = balance::withdraw_all(
                &mut prediction_event.outcome_pools[i]
            );
            balance::join(
                &mut prediction_event.outcome_pools[winning_idx],
                losing_balance,
            );
        };
        i = i + 1;
    };

    event::emit(EventResolved {
        event_id: object::id(prediction_event),
        winning_outcome,
        total_pool: prediction_event.total_pool,
        event_type: EVENT_TYPE_CRYPTO,
        oracle_price,
    });
}
