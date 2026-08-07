//! Entitlement — two auto-renewable subscriptions in one App Store group,
//! verified once and stored against the anonymous identity `crate::identity`
//! resolves.
//!
//! The division of labour with the client is the whole design. `StoreKit` answers
//! `Transaction.currentEntitlements` on the device, offline, so every piece of
//! UI gating reads from there and no screen ever waits on this server. What
//! lands here is the same purchase re-asserted as something the server can
//! check for itself, because one decision must not be the client's: whether a
//! caller may spend a language-model call. `assistant` reads [`service::tier`]
//! and never a field off a request — one call, resolved from the caller's own
//! row, with the pairing of tier and expiry left where it belongs.
//!
//! `verifier/` is the seam, in the shape `assistant::model` established — a
//! trait, a real implementation, and a scripted one for the tests.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
pub mod verifier;
