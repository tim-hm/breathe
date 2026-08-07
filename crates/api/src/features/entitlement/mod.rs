//! Entitlement — one auto-renewable subscription, verified once and stored
//! against the anonymous identity `crate::identity` resolves.
//!
//! The division of labour with the client is the whole design. `StoreKit` answers
//! `Transaction.currentEntitlements` on the device, offline, so every piece of
//! UI gating reads from there and no screen ever waits on this server. What
//! lands here is the same purchase re-asserted as something the server can
//! check for itself, because one decision must not be the client's: how much of
//! the language model a caller may spend. `assistant` reads
//! [`service::tier`] and never a field off a request.
//!
//! `verifier/` is the seam, in the shape `assistant::model` established — a
//! trait, a real implementation, and a scripted one for the tests.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
pub mod verifier;
