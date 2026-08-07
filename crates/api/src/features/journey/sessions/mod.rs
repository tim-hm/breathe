//! Sessions — the history itself: what a person breathed, when, and what that
//! adds up to.
//!
//! The append-only half of the journey. Nothing here updates a row; a session is
//! recorded once, deleted whole, or read back.

pub mod repository;
pub mod service;
pub mod types;
