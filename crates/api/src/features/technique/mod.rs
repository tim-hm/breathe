//! Technique — the catalogue of breathing techniques, the stages they play, and
//! the breathing foundations served alongside them.
//!
//! The foundations live here rather than in a feature of their own because the
//! contract puts them on `TechniqueService`: they are the other half of the
//! catalogue's reference data, read by the same client on the same terms.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
