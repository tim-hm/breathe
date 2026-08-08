//! Leaderboards — the same two tables read across everybody rather than down one
//! person.
//!
//! The one journey surface that is not about the caller alone, which is why it
//! is the one that has to count people it must not name — and the one that is
//! answered from a snapshot rather than from the history itself, because a
//! ranking cannot be narrowed to the twenty rows it shows.

pub mod repository;
pub mod service;
pub mod types;
