//! Profile — the answers onboarding collects, stored against the anonymous
//! identity that `crate::identity` resolves.
//!
//! The `users` row itself is created there, not here: it exists from the first
//! RPC of any kind, and this feature owns only what a person has told the app
//! about themselves.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
