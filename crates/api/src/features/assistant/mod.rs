//! Assistant — a language model reading the profile and the catalogue, and the
//! rules that answer when it cannot.
//!
//! The layers here are the usual three plus one: `model` is the seam a provider
//! sits behind, `openrouter` is the only file that knows which provider that
//! is, `breaker` stops calling one that keeps failing, and `fallback` answers
//! without it. That split is what makes everything except `openrouter` testable
//! with no network and no key.
//!
//! Reads across to `profile` and `technique` rather than holding its own copy
//! of either: the guidance is derived from the answers somebody gave and the
//! catalogue that is served to them, and a second copy of either would be a
//! second thing to keep in step.

pub mod breaker;
pub mod errors;
pub mod fallback;
pub mod handlers;
pub mod model;
pub mod openrouter;
pub mod prompt;
pub mod repository;
pub mod service;
pub mod types;
