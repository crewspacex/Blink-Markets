/// Module: blink_config
/// Governance, treasury, and market administration for the Blinkmarket platform
module blinkmarket::blink_config;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::sui::SUI;
use sui::event;
use sui::vec_map::{Self, VecMap};

// ============== Error Constants ==============

// Access control errors
const ENotAuthorized: u64 = 0;

// State errors
const EMarketNotActive: u64 = 100;

// ============== Core Structs ==============

/// Platform admin capability - grants full administrative control
public struct AdminCap has key, store {
    id: UID,
}

/// Capability to create events for a specific market
public struct MarketCreatorCap has key, store {
    id: UID,
    market_id: ID,
}

/// Market category container (e.g., NBA, eSports)
public struct Market has key, store {
    id: UID,
    name: vector<u8>,
    description: vector<u8>,
    min_stake: u64,
    max_stake: u64,
    platform_fee_bps: u64, // Platform fee in basis points
    is_active: bool,
    oracles: VecMap<address, bool>, // Authorized oracles
}

/// Platform fee collection treasury (generic over coin type)
public struct Treasury<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    total_collected: u64,
}

// ============== Events ==============

public struct MarketCreated has copy, drop {
    market_id: ID,
    name: vector<u8>,
}

// ============== Initialization ==============

/// Initialize the module - creates AdminCap and default SUI Treasury
fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, tx_context::sender(ctx));

    let treasury = Treasury<SUI> {
        id: object::new(ctx),
        balance: balance::zero<SUI>(),
        total_collected: 0,
    };
    transfer::share_object(treasury);
}

// ============== Market Management ==============

/// Create a new market category (admin only)
public fun create_market(
    _admin: &AdminCap,
    name: vector<u8>,
    description: vector<u8>,
    min_stake: u64,
    max_stake: u64,
    platform_fee_bps: u64,
    ctx: &mut TxContext,
): MarketCreatorCap {
    let market = Market {
        id: object::new(ctx),
        name,
        description,
        min_stake,
        max_stake,
        platform_fee_bps,
        is_active: true,
        oracles: vec_map::empty(),
    };

    let market_id = object::id(&market);

    event::emit(MarketCreated {
        market_id,
        name: market.name,
    });

    transfer::share_object(market);

    MarketCreatorCap {
        id: object::new(ctx),
        market_id,
    }
}

/// Add an oracle to the market
public fun add_oracle(
    _admin: &AdminCap,
    market: &mut Market,
    oracle_address: address,
) {
    if (!vec_map::contains(&market.oracles, &oracle_address)) {
        vec_map::insert(&mut market.oracles, oracle_address, true);
    };
}

/// Remove an oracle from the market
public fun remove_oracle(
    _admin: &AdminCap,
    market: &mut Market,
    oracle_address: address,
) {
    if (vec_map::contains(&market.oracles, &oracle_address)) {
        vec_map::remove(&mut market.oracles, &oracle_address);
    };
}

/// Set market active status
public fun set_market_active(
    _admin: &AdminCap,
    market: &mut Market,
    is_active: bool,
) {
    market.is_active = is_active;
}

/// Check if an address is an authorized oracle
public fun is_oracle(market: &Market, addr: address): bool {
    vec_map::contains(&market.oracles, &addr)
}

// ============== Treasury Management ==============

/// Create a treasury for a specific coin type (admin only)
public fun create_treasury<CoinType>(
    _admin: &AdminCap,
    ctx: &mut TxContext,
) {
    let treasury = Treasury<CoinType> {
        id: object::new(ctx),
        balance: balance::zero<CoinType>(),
        total_collected: 0,
    };
    transfer::share_object(treasury);
}

/// Withdraw fees from treasury (admin only)
public fun withdraw_fees<CoinType>(
    _admin: &AdminCap,
    treasury: &mut Treasury<CoinType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let withdraw_balance = balance::split(&mut treasury.balance, amount);
    coin::from_balance(withdraw_balance, ctx)
}

/// Add fees to treasury (package-internal function for other modules)
public(package) fun add_fee_to_treasury<CoinType>(
    treasury: &mut Treasury<CoinType>,
    fee_balance: Balance<CoinType>,
) {
    let fee_amount = balance::value(&fee_balance);
    balance::join(&mut treasury.balance, fee_balance);
    treasury.total_collected = treasury.total_collected + fee_amount;
}

// ============== View Functions ==============

/// Get treasury balance
public fun get_treasury_balance<CoinType>(treasury: &Treasury<CoinType>): u64 {
    balance::value(&treasury.balance)
}

/// Get total fees collected
public fun get_total_fees_collected<CoinType>(treasury: &Treasury<CoinType>): u64 {
    treasury.total_collected
}

/// Get market configuration
public fun get_market_min_stake(market: &Market): u64 {
    market.min_stake
}

public fun get_market_max_stake(market: &Market): u64 {
    market.max_stake
}

public fun get_market_fee_bps(market: &Market): u64 {
    market.platform_fee_bps
}

public fun is_market_active(market: &Market): bool {
    market.is_active
}

/// Get market ID from creator cap (package-internal)
public(package) fun get_creator_cap_market_id(cap: &MarketCreatorCap): ID {
    cap.market_id
}

/// Validate market is active (package-internal)
public(package) fun assert_market_active(market: &Market) {
    assert!(market.is_active, EMarketNotActive);
}

/// Validate market ID matches (package-internal)
public(package) fun assert_market_id_matches(market: &Market, expected_id: ID) {
    assert!(object::id(market) == expected_id, ENotAuthorized);
}

// ============== Test-only Functions ==============

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
