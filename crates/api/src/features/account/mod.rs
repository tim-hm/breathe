//! Account — Sign in with Apple, and the one place two identities become one.
//!
//! `crate::identity` resolves an anonymous id on every request and creates its
//! row; this feature is what attaches a credential to that row, so a person
//! reaching the app from a new device can be handed back the history they
//! already had. Signing in is never required — the free tier is the whole app on
//! one device — which is why this is a service of its own rather than a gate in
//! front of the others.
//!
//! It is also where an identity stops existing, by either of the two routes
//! there are. The merge a returning sign-in performs is documented in full on
//! `repository::merge`: what moves, what is summed, what is deliberately left
//! behind, and why each of those follows from the schema. `DeleteAccount` is the
//! other, and keeps nothing at all — it is the promise `web/privacy.html` makes
//! about erasure, and what Guideline 5.1.1(v) requires of any app that offers an
//! account.
//!
//! `verifier/` is the seam, in the shape `entitlement::verifier` established — a
//! trait, a real implementation, and a scripted one for the tests.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod verifier;
