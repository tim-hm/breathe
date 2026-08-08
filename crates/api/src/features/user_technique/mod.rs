//! User technique — the exercises a person composed for themselves, stored
//! against the anonymous identity `crate::identity` resolves so that they are
//! the same exercises on their phone and on their watch.
//!
//! Separate from `technique` because the two answer different questions. That
//! feature serves curated reference data to anybody who asks; this one serves
//! one caller their own rows, takes writes, and is the only place in the API
//! where the seeded safe ranges are *enforced* rather than merely published.
//! Those ranges are read from the catalogue rather than restated here — see
//! [`repository::phase_limits`].

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
