# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Blinkmarket is a Sui blockchain smart contract project written in the Move programming language (2024.beta edition). This is a scaffold-stage project ready for feature development.

## Build Commands

```bash
# Build the project
sui move build

# Run all tests
sui move test

# Build in dev mode (enables dev-dependencies)
sui move build -d

# Check test coverage
sui move coverage

# Generate documentation
sui move --doc
```

## Project Structure

- `Move.toml` - Package manifest with dependencies and addresses
- `sources/` - Move smart contract source code
- `tests/` - Unit test modules (files suffixed with `_tests.move`)
- `build/` - Compiled artifacts (auto-generated, gitignored)

## Move Code Conventions

- **Module namespace:** `blinkmarket::module_name`
- **Error constants:** PascalCase with `E` prefix (e.g., `ENotImplemented`)
- **Testing attributes:** Use `#[test_only]` for test modules, `#[test]` for test functions
- **Expected failures:** Use `#[expected_failure(abort_code = ...)]` for error testing
- **Error handling:** Use `abort` with error code constants

## Adding Dependencies (Move.toml)

```toml
[dependencies]
# Remote git dependency
MyPackage = { git = "https://some.remote/host.git", subdir = "path", rev = "main" }

# Local dependency
LocalPkg = { local = "../path/to/package" }
```

## Deployment

1. Build: `sui move build`
2. Publish: `sui client publish`
3. Record addresses: `sui move manage-package`

## Reference

Sui Move conventions: https://docs.sui.io/concepts/sui-move-concepts/conventions
