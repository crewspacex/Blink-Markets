#[test_only]
module blinkmarket::blinkmarket_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::clock;
use sui::unit_test;

use blinkmarket::blink_config::{
    Self,
    AdminCap,
    MarketCreatorCap,
    Market,
    Treasury,
};
use blinkmarket::blink_event::{
    Self,
    PredictionEvent,
};
use blinkmarket::blink_position::{
    Self,
    Position,
};

// Test addresses
const ADMIN: address = @0xAD;
const ORACLE: address = @0x0AC1E;
const USER_A: address = @0xA;
const USER_B: address = @0xB;
const USER_C: address = @0xC;

// Test constants
const MIN_STAKE: u64 = 1_000_000; // 0.001 SUI
const MAX_STAKE: u64 = 1_000_000_000; // 1 SUI
const PLATFORM_FEE_BPS: u64 = 200; // 2%
const DEFAULT_DURATION: u64 = 1_000_000_000_000; // duration in ms
const TEST_TARGET_PRICE: u128 = 6_200_000_000_000; // $62,000 with 1e8 precision

// Test-only coin type for generic treasury tests
public struct USDC has drop {}

// ============== Helper Functions ==============

fun setup_test(): Scenario {
    let mut scenario = ts::begin(ADMIN);
    {
        blink_config::init_for_testing(ts::ctx(&mut scenario));
    };
    scenario
}

fun create_test_market(scenario: &mut Scenario): MarketCreatorCap {
    ts::next_tx(scenario, ADMIN);
    let admin_cap = ts::take_from_sender<AdminCap>(scenario);

    let creator_cap = blink_config::create_market(
        &admin_cap,
        b"NBA",
        b"NBA Basketball Predictions",
        MIN_STAKE,
        MAX_STAKE,
        PLATFORM_FEE_BPS,
        ts::ctx(scenario),
    );

    ts::return_to_sender(scenario, admin_cap);
    creator_cap
}

fun add_oracle_to_market(scenario: &mut Scenario) {
    ts::next_tx(scenario, ADMIN);
    let admin_cap = ts::take_from_sender<AdminCap>(scenario);
    let mut market = ts::take_shared<Market>(scenario);

    blink_config::add_oracle(&admin_cap, &mut market, ORACLE);

    ts::return_shared(market);
    ts::return_to_sender(scenario, admin_cap);
}

fun create_test_event(scenario: &mut Scenario, creator_cap: &MarketCreatorCap) {
    ts::next_tx(scenario, ADMIN);
    let market = ts::take_shared<Market>(scenario);

    let outcome_labels = vector[b"Yes", b"No"];
    blink_event::create_manual_event<SUI>(
        creator_cap,
        &market,
        b"Will the next shot be a 3-pointer?",
        outcome_labels,
        DEFAULT_DURATION,
        ts::ctx(scenario),
    );

    ts::return_shared(market);
}

fun create_test_crypto_event(scenario: &mut Scenario, creator_cap: &MarketCreatorCap) {
    ts::next_tx(scenario, ADMIN);
    let market = ts::take_shared<Market>(scenario);

    blink_event::create_crypto_event<SUI>(
        creator_cap,
        &market,
        b"BTC above $62,000?",
        test_feed_id(),
        TEST_TARGET_PRICE,
        DEFAULT_DURATION,
        ts::ctx(scenario),
    );

    ts::return_shared(market);
}

fun test_feed_id(): vector<u8> {
    let mut feed_id = vector::empty<u8>();
    let mut i = 0u8;
    while ((i as u64) < 32) {
        feed_id.push_back(i);
        i = i + 1;
    };
    feed_id
}

fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// ============== Initialization Tests ==============

#[test]
fun test_init_creates_admin_cap_and_treasury() {
    let mut scenario = setup_test();

    // Check AdminCap was transferred to admin
    ts::next_tx(&mut scenario, ADMIN);
    {
        assert!(ts::has_most_recent_for_sender<AdminCap>(&scenario), 0);
    };

    // Check Treasury was shared
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        assert!(blink_config::get_treasury_balance(&treasury) == 0, 1);
        assert!(blink_config::get_total_fees_collected(&treasury) == 0, 2);
        ts::return_shared(treasury);
    };

    ts::end(scenario);
}

// ============== Market Management Tests ==============

#[test]
fun test_create_market() {
    let mut scenario = setup_test();

    let creator_cap = create_test_market(&mut scenario);

    // Verify market was created
    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        assert!(blink_config::get_market_min_stake(&market) == MIN_STAKE, 0);
        assert!(blink_config::get_market_max_stake(&market) == MAX_STAKE, 1);
        assert!(blink_config::get_market_fee_bps(&market) == PLATFORM_FEE_BPS, 2);
        assert!(blink_config::is_market_active(&market), 3);
        ts::return_shared(market);
    };

    // Clean up
    ts::next_tx(&mut scenario, ADMIN);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_add_and_remove_oracle() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    // Add oracle
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut market = ts::take_shared<Market>(&scenario);

        blink_config::add_oracle(&admin_cap, &mut market, ORACLE);
        assert!(blink_config::is_oracle(&market, ORACLE), 0);

        ts::return_shared(market);
        ts::return_to_sender(&scenario, admin_cap);
    };

    // Remove oracle
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut market = ts::take_shared<Market>(&scenario);

        blink_config::remove_oracle(&admin_cap, &mut market, ORACLE);
        assert!(!blink_config::is_oracle(&market, ORACLE), 1);

        ts::return_shared(market);
        ts::return_to_sender(&scenario, admin_cap);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_set_market_active() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    // Deactivate market
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut market = ts::take_shared<Market>(&scenario);

        blink_config::set_market_active(&admin_cap, &mut market, false);
        assert!(!blink_config::is_market_active(&market), 0);

        ts::return_shared(market);
        ts::return_to_sender(&scenario, admin_cap);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Event Lifecycle Tests ==============

#[test]
fun test_event_lifecycle_created_to_open() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Verify event is created
    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_created(), 0);
        ts::return_shared(event);
    };

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_open(), 1);
        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_auto_lock_on_resolve() {
    // Tests that resolve_manual_event atomically locks then resolves
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_open(), 0);
        ts::return_shared(event);
    };

    // Advance clock past betting end time
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Oracle resolves (auto-locks internally)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);

        blink_event::resolve_manual_event(
            &mut event,
            &market,
            0,
            &clock,
            ts::ctx(&mut scenario),
        );

        // Should be RESOLVED (went through LOCKED internally)
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_resolved(), 1);

        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_event_cancellation() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Open then cancel
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        blink_event::cancel_event(&creator_cap, &mut event);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_cancelled(), 0);
        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Betting Tests ==============

#[test]
fun test_place_bet() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Place bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario)); // 0.1 SUI
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0, // outcome index (Yes)
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        // Verify position
        assert!(blink_position::get_position_stake(&position) == 98_000_000, 0); // 2% fee deducted
        assert!(blink_position::get_position_outcome(&position) == 0, 1);
        assert!(!blink_position::is_position_claimed(&position), 2);

        // Verify treasury collected fee
        assert!(blink_config::get_treasury_balance(&treasury) == 2_000_000, 3); // 2% of 100M

        // Verify event pool
        assert!(blink_event::get_total_pool(&event) == 98_000_000, 4);

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 202, location = blink_position)] // EStakeTooLow
fun test_place_bet_stake_too_low() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Try to place bet with stake below minimum
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100, ts::ctx(&mut scenario)); // Too low
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 101, location = blink_event)] // EEventNotOpen
fun test_place_bet_event_not_open() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Event is in CREATED state (not opened)
    ts::next_tx(&mut scenario, USER_A);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 301, location = blink_event)] // EBettingClosed
fun test_place_bet_after_betting_window() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    // Create event with short betting window
    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);

        let outcome_labels = vector[b"Yes", b"No"];
        blink_event::create_manual_event<SUI>(
            &creator_cap,
            &market,
            b"Test event",
            outcome_labels,
            100, // duration in ms
            ts::ctx(&mut scenario),
        );

        ts::return_shared(market);
    };

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Set clock past betting window (event has 100ms duration)
    clock::set_for_testing(&mut clock, 200); // After betting window

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Resolution and Payout Tests ==============

#[test]
fun test_full_betting_resolution_and_claim() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets 100 on Yes (outcome 0)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0, // Yes
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // User B bets 200 on Yes (outcome 0)
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0, // Yes
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // User C bets 300 on No (outcome 1)
    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(300_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            1, // No
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_C);
    };

    // Advance clock past betting end time
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Oracle resolves - Yes wins (outcome 0)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);

        blink_event::resolve_manual_event(
            &mut event,
            &market,
            0, // Yes wins
            &clock,
            ts::ctx(&mut scenario),
        );

        assert!(blink_event::get_event_status(&event) == blink_event::get_status_resolved(), 0);

        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A claims winnings
    // Total pool = 588M (after 2% fees on each bet: 98 + 196 + 294 = 588)
    // Yes pool = 294M (98 + 196)
    // User A stake = 98M, expected payout = (98/294) * 588 = 196M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);

        let winnings = blink_position::claim_winnings(
            &mut event,
            &mut position,
            ts::ctx(&mut scenario),
        );

        // Verify payout calculation: (98/294) * 588 = 196
        assert!(coin::value(&winnings) == 196_000_000, 1);
        assert!(blink_position::is_position_claimed(&position), 2);

        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 105, location = blink_position)] // EPositionAlreadyClaimed
fun test_double_claim_prevention() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A places bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Advance clock past betting end time and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // First claim (should succeed)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);

        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));

        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    // Second claim (should fail)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);

        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));

        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 106, location = blink_position)] // ENotWinningOutcome
fun test_claim_losing_position() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets on No (outcome 1)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            1, // No
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Advance clock and resolve - Yes wins (outcome 0)
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario)); // Yes wins
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A tries to claim (should fail - they bet on No)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);

        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));

        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Refund Tests ==============

#[test]
fun test_refund_on_cancelled_event() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A places bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Cancel the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::cancel_event(&creator_cap, &mut event);
        ts::return_shared(event);
    };

    // User A claims refund
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_sender<Position<SUI>>(&scenario);

        let refund = blink_position::claim_refund(&mut event, position, ts::ctx(&mut scenario));

        // Refund should be net stake (after platform fee)
        assert!(coin::value(&refund) == 98_000_000, 0);

        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Cancel Bet Tests ==============

#[test]
fun test_cancel_bet_before_lock() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A places bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // User A cancels bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_sender<Position<SUI>>(&scenario);

        let refund = blink_position::cancel_bet(&mut event, position, ts::ctx(&mut scenario));

        // 1% cancellation fee: 98M * 0.99 = 97.02M
        assert!(coin::value(&refund) == 97_020_000, 0);

        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 302, location = blink_position)] // EEventAlreadyLocked
fun test_cancel_bet_after_resolve_fails() {
    // After resolve, event status is RESOLVED (not OPEN), so cancel should fail
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A places bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(
            &mut event,
            &market,
            &mut treasury,
            0,
            stake,
            &clock,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Advance clock and resolve the event
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A tries to cancel bet (should fail - event is resolved)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_sender<Position<SUI>>(&scenario);

        let refund = blink_position::cancel_bet(&mut event, position, ts::ctx(&mut scenario));

        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Oracle Authorization Tests ==============

#[test]
#[expected_failure(abort_code = 1, location = blink_event)] // ENotOracle
fun test_non_oracle_cannot_resolve() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Advance clock past betting end time
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Non-oracle tries to resolve (should fail)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);

        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));

        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== View Function Tests ==============

#[test]
fun test_get_odds() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Place bets
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake1 = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position1 = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake1, &clock, ts::ctx(&mut scenario));

        let stake2 = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position2 = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake2, &clock, ts::ctx(&mut scenario));

        // Check odds
        let odds = blink_event::get_odds(&event);
        assert!(*odds.borrow(0) == 98_000_000, 0); // 100M - 2% = 98M
        assert!(*odds.borrow(1) == 196_000_000, 1); // 200M - 2% = 196M

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position1);
        unit_test::destroy(position2);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_calculate_potential_payout() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Place initial bet
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));

        // Calculate potential payout for a 100M bet on outcome 1
        let potential = blink_event::calculate_potential_payout(&event, 1, 100_000_000);
        // No pool is currently empty (0), so function returns stake_amount directly (1:1 payout)
        assert!(potential == 100_000_000, 0);

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Admin Tests ==============

#[test]
fun test_withdraw_fees() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Place bet to generate fees
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));

        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Admin withdraws fees
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);

        assert!(blink_config::get_treasury_balance(&treasury) == 2_000_000, 0);

        let withdrawn = blink_config::withdraw_fees(&admin_cap, &mut treasury, 1_000_000, ts::ctx(&mut scenario));
        assert!(coin::value(&withdrawn) == 1_000_000, 1);
        assert!(blink_config::get_treasury_balance(&treasury) == 1_000_000, 2);

        ts::return_shared(treasury);
        ts::return_to_sender(&scenario, admin_cap);
        unit_test::destroy(withdrawn);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Event with Multiple Outcomes Test ==============

#[test]
fun test_multi_outcome_event() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    // Create event with 4 outcomes (Team A, Team B, Draw, Other)
    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);

        let outcome_labels = vector[b"Team A", b"Team B", b"Draw", b"Other"];
        blink_event::create_manual_event<SUI>(
            &creator_cap,
            &market,
            b"Who wins the match?",
            outcome_labels,
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(market);
    };

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);

        // Verify 4 outcomes
        let odds = blink_event::get_odds(&event);
        assert!(odds.length() == 4, 0);

        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 205, location = blink_event)] // ETooFewOutcomes
fun test_too_few_outcomes() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    // Try to create event with only 1 outcome
    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);

        let outcome_labels = vector[b"Only One"];
        blink_event::create_manual_event<SUI>(
            &creator_cap,
            &market,
            b"Invalid event",
            outcome_labels,
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(market);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Additional Tests: Multiple Winners Claiming ==============

#[test]
fun test_multiple_winners_claim_correct_proportional_payout() {
    // Scenario: Two winners (A and B) both bet on outcome 0 (Yes),
    // one loser (C) bet on outcome 1 (No).
    // A bets 100M, B bets 200M, C bets 300M
    // After fees (2%): A=98M, B=196M, C=294M. Total pool=588M.
    // Winning pool (Yes) = 294M.
    // A payout: (98/294)*588 = 196M
    // B payout: (196/294)*588 = 392M
    // Total payout: 196+392 = 588M = total pool
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets 100M on Yes (outcome 0)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // User B bets 200M on Yes (outcome 0)
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // User C bets 300M on No (outcome 1)
    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(300_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_C);
    };

    // Advance clock and resolve - Yes wins (outcome 0)
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A claims winnings: (98/294)*588 = 196M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 196_000_000, 0);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    // User B claims winnings: (196/294)*588 = 392M
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 392_000_000, 1);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    // After both claims, total_pool tracking should still be 588M
    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        assert!(blink_event::get_total_pool(&event) == 588_000_000, 2);
        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Owner Verification Tests ==============

#[test]
#[expected_failure(abort_code = 107, location = blink_position)]
fun test_claim_winnings_wrong_owner() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // Advance clock and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // Transfer position to User B, then User C (not the owner) tries to claim
    ts::next_tx(&mut scenario, USER_A);
    {
        let position = ts::take_from_sender<Position<SUI>>(&scenario);
        transfer::public_transfer(position, USER_B);
    };

    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_address<Position<SUI>>(&scenario, USER_B);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_to_address(USER_B, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 107, location = blink_position)]
fun test_claim_refund_wrong_owner() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::cancel_event(&creator_cap, &mut event);
        ts::return_shared(event);
    };

    // Transfer A's position to B, then C tries to claim refund
    ts::next_tx(&mut scenario, USER_A);
    {
        let position = ts::take_from_sender<Position<SUI>>(&scenario);
        transfer::public_transfer(position, USER_B);
    };

    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_address<Position<SUI>>(&scenario, USER_B);
        let refund = blink_position::claim_refund(&mut event, position, ts::ctx(&mut scenario));
        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Resolution Timestamp Test ==============

#[test]
fun test_resolved_at_timestamp() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Open the event at time 0
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Advance clock past betting end time to a specific resolve time
    let resolve_time = DEFAULT_DURATION + 12345;
    clock::set_for_testing(&mut clock, resolve_time);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        assert!(blink_event::get_resolved_at(&event) == resolve_time, 0);
        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Winning Pool Merge Verification Test ==============

#[test]
fun test_losing_pools_merged_into_winning_pool_on_resolve() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Verify pools before resolution
    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let odds = blink_event::get_odds(&event);
        assert!(*odds.borrow(0) == 98_000_000, 0);
        assert!(*odds.borrow(1) == 196_000_000, 1);
        ts::return_shared(event);
    };

    // Advance clock and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // After resolution: winning pool should have all funds
    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let odds = blink_event::get_odds(&event);
        assert!(*odds.borrow(0) == 294_000_000, 2);
        assert!(*odds.borrow(1) == 0, 3);
        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Single Winner Gets Entire Pool Test ==============

#[test]
fun test_single_winner_gets_entire_pool() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets 100M on Yes -> net 98M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // User B bets 500M on No -> net 490M
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(500_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Advance clock and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // Sole winner gets entire pool: (98/98)*588 = 588M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 588_000_000, 0);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Three-Outcome Event Test ==============

#[test]
fun test_three_outcome_resolution_and_claim() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        blink_event::create_manual_event<SUI>(
            &creator_cap,
            &market,
            b"Who wins? A, B, or Draw",
            vector[b"Team A", b"Team B", b"Draw"],
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(market);
    };

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // A bets 100M on Team A (0) -> net 98M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // B bets 200M on Team B (1) -> net 196M
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // C bets 300M on Draw (2) -> net 294M
    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(300_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 2, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_C);
    };

    // Advance clock and resolve: Draw wins (outcome 2)
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 2, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // C wins entire pool: (294/294)*588 = 588M
    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 588_000_000, 0);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    // All pools should be empty after claim
    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let odds = blink_event::get_odds(&event);
        assert!(*odds.borrow(0) == 0, 1);
        assert!(*odds.borrow(1) == 0, 2);
        assert!(*odds.borrow(2) == 0, 3);
        ts::return_shared(event);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Position Owner View Function Test ==============

#[test]
fun test_get_position_owner() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        assert!(blink_position::get_position_owner(&position) == USER_A, 0);
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        unit_test::destroy(position);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Equal Stakes Test ==============

#[test]
fun test_equal_stakes_on_winning_side() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // A and B each bet 100M on Yes -> net 98M each
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // C bets 100M on No -> net 98M
    ts::next_tx(&mut scenario, USER_C);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_C);
    };

    // Advance clock and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // Each winner: (98/196)*294 = 147M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 147_000_000, 0);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 147_000_000, 1);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Large Value Overflow Prevention Test ==============

#[test]
fun test_large_values_no_overflow() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        blink_event::create_manual_event<SUI>(
            &creator_cap,
            &market,
            b"Large value test",
            vector[b"Yes", b"No"],
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(market);
    };

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(1_000_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(1_000_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Advance clock and resolve
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(&mut event, &market, 0, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A claims: (980M * 1960M) / 980M = 1960M
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 1_960_000_000, 0);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Multiple Refunds on Cancelled Event ==============

#[test]
fun test_multiple_refunds_on_cancelled_event() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    // Create clock
    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(200_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::cancel_event(&creator_cap, &mut event);
        ts::return_shared(event);
    };

    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_sender<Position<SUI>>(&scenario);
        let refund = blink_position::claim_refund(&mut event, position, ts::ctx(&mut scenario));
        assert!(coin::value(&refund) == 98_000_000, 0);
        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let position = ts::take_from_sender<Position<SUI>>(&scenario);
        let refund = blink_position::claim_refund(&mut event, position, ts::ctx(&mut scenario));
        assert!(coin::value(&refund) == 196_000_000, 1);
        ts::return_shared(event);
        unit_test::destroy(refund);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

// ============== Crypto Event Tests ==============

#[test]
fun test_create_crypto_event() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        blink_event::create_crypto_event<SUI>(
            &creator_cap,
            &market,
            b"BTC above $62,000?",
            test_feed_id(),
            TEST_TARGET_PRICE,
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(market);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        assert!(blink_event::get_event_type(&event) == blink_event::get_event_type_crypto(), 0);
        assert!(blink_event::get_target_price(&event) == TEST_TARGET_PRICE, 1);
        assert!(blink_event::get_oracle_feed_id(&event) == test_feed_id(), 2);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_created(), 3);
        ts::return_shared(event);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 210, location = blink_event)] // EInvalidFeedId
fun test_create_crypto_event_invalid_feed_id() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        // Only 16 bytes instead of 32
        let bad_feed_id = vector[0u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
        blink_event::create_crypto_event<SUI>(
            &creator_cap,
            &market,
            b"BTC test",
            bad_feed_id,
            TEST_TARGET_PRICE,
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(market);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 211, location = blink_event)] // ETargetPriceZero
fun test_create_crypto_event_zero_target_price() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let market = ts::take_shared<Market>(&scenario);
        blink_event::create_crypto_event<SUI>(
            &creator_cap,
            &market,
            b"BTC test",
            test_feed_id(),
            0, // zero target price
            DEFAULT_DURATION,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(market);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_resolve_crypto_price_above() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_crypto_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets on Above (outcome 0)
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    // User B bets on Below (outcome 1)
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Advance clock past betting end
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Oracle resolves with price above target ($65,000 > $62,000)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_crypto_event_for_testing(
            &mut event,
            &market,
            65_000_000_000_000_000_000_000, // $65,000
            &clock,
            ts::ctx(&mut scenario),
        );
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_resolved(), 0);
        assert!(blink_event::get_winning_outcome(&event) == 0, 1); // Above wins
        assert!(blink_event::get_oracle_price_at_resolution(&event) == 65_000_000_000_000_000_000_000, 2);
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User A (Above) claims winnings: entire pool
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        // Both pools after 2% fee: 98M + 98M = 196M total, sole winner gets all
        assert!(coin::value(&winnings) == 196_000_000, 3);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_resolve_crypto_price_below() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_crypto_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets on Above, User B bets on Below
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Advance clock past betting end
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Oracle resolves with price below target ($59,000 < $62,000)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_crypto_event_for_testing(
            &mut event,
            &market,
            59_000_000_000_000_000_000_000, // $59,000
            &clock,
            ts::ctx(&mut scenario),
        );
        assert!(blink_event::get_winning_outcome(&event) == 1, 0); // Below wins
        ts::return_shared(event);
        ts::return_shared(market);
    };

    // User B (Below) claims winnings
    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let mut position = ts::take_from_sender<Position<SUI>>(&scenario);
        let winnings = blink_position::claim_winnings(&mut event, &mut position, ts::ctx(&mut scenario));
        assert!(coin::value(&winnings) == 196_000_000, 1);
        ts::return_shared(event);
        ts::return_to_sender(&scenario, position);
        unit_test::destroy(winnings);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_resolve_crypto_price_exact() {
    // When oracle_price == target_price, outcome 0 (Above) wins (>=)
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_crypto_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // User A bets on Above, User B bets on Below
    ts::next_tx(&mut scenario, USER_A);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 0, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_A);
    };

    ts::next_tx(&mut scenario, USER_B);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        let mut treasury = ts::take_shared<Treasury<SUI>>(&scenario);
        let stake = mint_sui(100_000_000, ts::ctx(&mut scenario));
        let position = blink_position::place_bet(&mut event, &market, &mut treasury, 1, stake, &clock, ts::ctx(&mut scenario));
        ts::return_shared(event);
        ts::return_shared(market);
        ts::return_shared(treasury);
        transfer::public_transfer(position, USER_B);
    };

    // Advance clock past betting end
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Oracle resolves with price exactly equal to target
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_crypto_event_for_testing(
            &mut event,
            &market,
            TEST_TARGET_PRICE, // exact match
            &clock,
            ts::ctx(&mut scenario),
        );
        // >= means Above wins when equal
        assert!(blink_event::get_winning_outcome(&event) == 0, 0); // Above wins
        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 208, location = blink_event)] // ENotCryptoEvent
fun test_resolve_crypto_on_manual_event_fails() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap); // manual event

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Advance clock past betting end
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Try to resolve manual event with crypto resolve function (should fail)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_crypto_event_for_testing(
            &mut event,
            &market,
            65_000_000_000_000_000_000_000,
            &clock,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 209, location = blink_event)] // ENotManualEvent
fun test_resolve_manual_on_crypto_event_fails() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_crypto_event(&mut scenario, &creator_cap); // crypto event

    ts::next_tx(&mut scenario, ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Advance clock past betting end
    clock::set_for_testing(&mut clock, DEFAULT_DURATION + 1);

    // Try to resolve crypto event with manual resolve function (should fail)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(
            &mut event,
            &market,
            0,
            &clock,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 101, location = blink_event)] // EEventNotOpen
fun test_resolve_before_betting_end_fails() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    add_oracle_to_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        blink_event::open_event(&creator_cap, &mut event, &clock);
        ts::return_shared(event);
    };

    // Do NOT advance clock - betting is still open
    // Oracle tries to resolve (should fail - betting not ended)
    ts::next_tx(&mut scenario, ORACLE);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        let market = ts::take_shared<Market>(&scenario);
        blink_event::resolve_manual_event(
            &mut event,
            &market,
            0,
            &clock,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(event);
        ts::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_cancel_from_created_state() {
    // Verify cancel works from CREATED state (before open)
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_created(), 0);
        blink_event::cancel_event(&creator_cap, &mut event);
        assert!(blink_event::get_event_status(&event) == blink_event::get_status_cancelled(), 1);
        ts::return_shared(event);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}

#[test]
fun test_create_treasury_generic() {
    let mut scenario = setup_test();

    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        blink_config::create_treasury<USDC>(&admin_cap, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, admin_cap);
    };

    // Verify the USDC treasury was created and can be accessed
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<Treasury<USDC>>(&scenario);
        assert!(blink_config::get_treasury_balance(&treasury) == 0, 0);
        assert!(blink_config::get_total_fees_collected(&treasury) == 0, 1);
        ts::return_shared(treasury);
    };

    ts::end(scenario);
}

// ============== Manual Event Type Verification ==============

#[test]
fun test_manual_event_type() {
    let mut scenario = setup_test();
    let creator_cap = create_test_market(&mut scenario);
    create_test_event(&mut scenario, &creator_cap);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let event = ts::take_shared<PredictionEvent<SUI>>(&scenario);
        assert!(blink_event::get_event_type(&event) == blink_event::get_event_type_manual(), 0);
        assert!(blink_event::get_oracle_feed_id(&event) == vector::empty<u8>(), 1);
        assert!(blink_event::get_target_price(&event) == 0, 2);
        ts::return_shared(event);
    };

    unit_test::destroy(creator_cap);
    ts::end(scenario);
}
