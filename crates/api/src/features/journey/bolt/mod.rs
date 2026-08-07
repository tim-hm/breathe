//! BOLT — the controlled-pause measurements a person takes deliberately, one at
//! a time.
//!
//! Separate from `sessions` because it changes for different reasons: a pause is
//! a self-administered test rather than a practice, and the only question anyone
//! asks of the history is what the best one was.

pub mod repository;
pub mod service;
