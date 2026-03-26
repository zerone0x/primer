<!-- paic:sha256:generated-by-demo -->
# fastcache

## Project Overview
A Redis-compatible in-memory cache with persistence and cluster support

**Stack**: Rust / tokio

## Build & Test
```bash
# Build
cargo build --release

# Test
cargo test

# Lint
cargo clippy -- -D warnings

# Bench
cargo bench
```

## Code Style & Constraints
- Use thiserror for library errors, anyhow for binary errors -- never mix them
- All network I/O must go through tokio -- no blocking calls on the async runtime
- Pin MSRV to 1.75 in Cargo.toml and test in CI -- do not use nightly-only features
- RESP protocol parsing must be zero-copy where possible -- avoid String allocations for commands
- All public API types must implement Send + Sync -- the cache is shared across async tasks

## Current Phase
Phase: **growth**
Adding features -- fastcache has users and must stay Redis-compatible

---
<!-- AGENTS.md evolution: To propose changes, create .ai/evolution/proposals/<name>.yaml -->
<!-- Compatible with Codex and Copilot Workspace. Run `paic evolve` to review proposals. -->
