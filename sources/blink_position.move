/// Module: blink_position
/// User betting actions and position management for prediction markets
module blinkmarket::blink_position;

use sui::coin::{Self, Coin};
use sui::balance;
use sui::clock::Clock;
use sui::event;

use blinkmarket::blink_config::{Self, Market, Treasury};
use blinkmarket::blink_event::{Self, PredictionEvent};

// ============== Error Constants ==============

// State errors
const EEventAlreadyLocked: u64 = 302;
const EPositionAlreadyClaimed: u64 = 105;
const ENotWinningOutcome: u64 = 106;
const ENotAuthorized: u64 = 107; // Caller is not the position owner

// Validation errors
const EStakeTooLow: u64 = 202;
const EStakeTooHigh: u64 = 203;
const EEventMismatch: u64 = 207;

// Configuration constants
const CANCELLATION_FEE_BPS: u64 = 100; // 1% = 100 basis points

// ============== Core Structs ==============

/// User's stake on a specific outcome (generic over coin type)
public struct Position<phantom CoinType> has key, store {
    id: UID,
    event_id: ID,
    outcome_index: u8,
    stake_amount: u64,
    is_claimed: bool,
    owner: address,
}

// ============== Events ==============

public struct BetPlaced has copy, drop {
    event_id: ID,
    position_id: ID,
    outcome_index: u8,
    stake_amount: u64,
    bettor: address,
}

public struct BetCancelled has copy, drop {
    event_id: ID,
    position_id: ID,
    refund_amount: u64,
    fee_amount: u64,
}

public struct WinningsClaimed has copy, drop {
    event_id: ID,
    position_id: ID,
    payout_amount: u64,
    claimer: address,
}

public struct RefundClaimed has copy, drop {
    event_id: ID,
    position_id: ID,
    refund_amount: u64,
    claimer: address,
}

// ============== Betting ==============

/// Place a bet on an outcome
public fun place_bet<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    market: &Market,
    treasury: &mut Treasury<CoinType>,
    outcome_index: u8,
    stake: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Position<CoinType> {
    // Validate market and event status
    blink_config::assert_market_active(market);
    assert!(
        blink_event::get_event_market_id(prediction_event) == object::id(market),
        EEventMismatch
    );
    blink_event::assert_event_open(prediction_event);

    // Validate timing
    blink_event::assert_betting_time_valid(prediction_event, clock);

    // Validate outcome index
    blink_event::assert_valid_outcome(prediction_event, outcome_index);

    // Validate stake amount
    let stake_value = coin::value(&stake);
    assert!(stake_value >= blink_config::get_market_min_stake(market), EStakeTooLow);
    assert!(stake_value <= blink_config::get_market_max_stake(market), EStakeTooHigh);

    // Calculate and extract platform fee
    let fee_amount = (stake_value * blink_config::get_market_fee_bps(market)) / blink_event::get_bps_denominator();
    let net_stake = stake_value - fee_amount;

    let mut stake_balance = coin::into_balance(stake);

    // Transfer fee to treasury
    if (fee_amount > 0) {
        let fee_balance = balance::split(&mut stake_balance, fee_amount);
        blink_config::add_fee_to_treasury(treasury, fee_balance);
    };

    // Add net stake to outcome pool
    blink_event::add_to_pool(prediction_event, outcome_index, stake_balance, net_stake);

    let bettor = tx_context::sender(ctx);
    let position = Position<CoinType> {
        id: object::new(ctx),
        event_id: object::id(prediction_event),
        outcome_index,
        stake_amount: net_stake,
        is_claimed: false,
        owner: bettor,
    };

    event::emit(BetPlaced {
        event_id: object::id(prediction_event),
        position_id: object::id(&position),
        outcome_index,
        stake_amount: net_stake,
        bettor,
    });

    position
}

/// Cancel a bet before event is locked (1% fee)
public fun cancel_bet<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    position: Position<CoinType>,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // Can only cancel when event is still OPEN
    assert!(blink_event::get_event_status(prediction_event) == 1, EEventAlreadyLocked); // STATUS_OPEN = 1
    assert!(position.event_id == object::id(prediction_event), EEventMismatch);
    assert!(!position.is_claimed, EPositionAlreadyClaimed);

    let Position { id, event_id: _, outcome_index, stake_amount, is_claimed: _, owner: _ } = position;
    let position_id = object::uid_to_inner(&id);
    object::delete(id);

    // Calculate cancellation fee
    let fee_amount = (stake_amount * CANCELLATION_FEE_BPS) / blink_event::get_bps_denominator();
    let refund_amount = stake_amount - fee_amount;

    // Withdraw from outcome pool
    let refund_balance = blink_event::remove_from_pool(
        prediction_event,
        outcome_index,
        refund_amount
    );

    // Fee stays in the pool (distributed to winners)

    event::emit(BetCancelled {
        event_id: object::id(prediction_event),
        position_id,
        refund_amount,
        fee_amount,
    });

    coin::from_balance(refund_balance, ctx)
}

// ============== Claims ==============

/// Claim winnings for a winning position
public fun claim_winnings<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    position: &mut Position<CoinType>,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // Validate ownership
    assert!(tx_context::sender(ctx) == position.owner, ENotAuthorized);

    // Validate event is resolved
    blink_event::assert_event_resolved(prediction_event);
    assert!(position.event_id == object::id(prediction_event), EEventMismatch);
    assert!(!position.is_claimed, EPositionAlreadyClaimed);
    assert!(
        blink_event::is_winning_outcome(prediction_event, position.outcome_index),
        ENotWinningOutcome
    );

    // Calculate payout: (user_stake / winning_pool_at_resolution) * total_pool
    let winning_pool_balance = blink_event::get_winning_pool_at_resolution(prediction_event);
    let total_pool = blink_event::get_total_pool_amount(prediction_event);

    // Payout calculation with u128 to avoid overflow
    let numerator = (position.stake_amount as u128) * (total_pool as u128);
    let payout_amount = (numerator / (winning_pool_balance as u128)) as u64;

    // Mark as claimed
    position.is_claimed = true;

    // Withdraw payout from the winning pool
    let payout_balance = blink_event::withdraw_payout(prediction_event, payout_amount);

    let claimer = tx_context::sender(ctx);
    event::emit(WinningsClaimed {
        event_id: object::id(prediction_event),
        position_id: object::id(position),
        payout_amount: balance::value(&payout_balance),
        claimer,
    });

    coin::from_balance(payout_balance, ctx)
}

/// Claim refund for a cancelled event
public fun claim_refund<CoinType>(
    prediction_event: &mut PredictionEvent<CoinType>,
    position: Position<CoinType>,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // Validate ownership
    assert!(tx_context::sender(ctx) == position.owner, ENotAuthorized);

    // Validate event is cancelled
    blink_event::assert_event_cancelled(prediction_event);
    assert!(position.event_id == object::id(prediction_event), EEventMismatch);
    assert!(!position.is_claimed, EPositionAlreadyClaimed);

    let Position { id, event_id: _, outcome_index, stake_amount, is_claimed: _, owner: _ } = position;
    let position_id = object::uid_to_inner(&id);
    object::delete(id);

    // Withdraw full stake from outcome pool
    let refund_balance = blink_event::remove_from_pool(
        prediction_event,
        outcome_index,
        stake_amount
    );

    let claimer = tx_context::sender(ctx);
    event::emit(RefundClaimed {
        event_id: object::id(prediction_event),
        position_id,
        refund_amount: stake_amount,
        claimer,
    });

    coin::from_balance(refund_balance, ctx)
}

// ============== View Functions ==============

/// Get position details
public fun get_position_stake<CoinType>(position: &Position<CoinType>): u64 {
    position.stake_amount
}

public fun get_position_outcome<CoinType>(position: &Position<CoinType>): u8 {
    position.outcome_index
}

public fun is_position_claimed<CoinType>(position: &Position<CoinType>): bool {
    position.is_claimed
}

public fun get_position_owner<CoinType>(position: &Position<CoinType>): address {
    position.owner
}
