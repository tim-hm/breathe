//! Assistant — a language model reading the profile and the catalogue, and the
//! rules that answer when it cannot.
//!
//! The usual three layers, plus two of this feature's own. `model/` is the seam
//! a provider sits behind — the trait, the one file that knows which provider it
//! is, the breaker that stops calling one that keeps failing, and the client
//! installed when there is no key at all. `fallback` answers without any of
//! them. That split is what makes everything except `model/openrouter` testable
//! with no network and no key.
//!
//! `prompt` and `parse` are deliberately separate: asking for something and
//! believing the answer are different jobs, and only the second one is
//! load-bearing for safety.
//!
//! Reads across to `profile`, `technique` and `entitlement` rather than holding
//! its own copy of any of them: the guidance is derived from the answers
//! somebody gave and the catalogue that is served to them, and a second copy of
//! either would be a second thing to keep in step. Each read goes through the
//! owning feature's *service* and comes back as that feature's domain type, so
//! nothing here holds a row struct and a schema change stays in one directory.

pub mod errors;
pub mod fallback;
pub mod handlers;
pub mod model;
pub mod parse;
pub mod prompt;
pub mod repository;
pub mod service;
pub mod types;
