//! Integration tests: the router the binary serves, over a real Postgres.
//!
//! One test binary rather than one per file — Cargo treats `tests/e2e/main.rs`
//! as a single target, so the harness compiles once and no module is dead code
//! in some other binary's build.
//!
//! Every test here needs a running database (`mise run dev:db`); `mise run
//! test:e2e` starts one.

// A harness failure has no caller to return an error to — the test must abort
// and name what was unreachable. `clippy.toml` re-allows these inside `#[test]`
// functions, which does not cover the harness's own helpers.
#![allow(clippy::expect_used, clippy::panic)]

mod account;
mod assistant;
mod entitlement;
mod harness;
mod health;
mod journey;
mod profile;
mod technique;
