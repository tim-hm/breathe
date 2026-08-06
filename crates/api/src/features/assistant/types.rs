//! The assistant's domain vocabulary, and the numbers that bound what it costs.

/// One technique the assistant is putting forward, and the sentence that
/// justifies it.
///
/// The slug is always one the catalogue serves: a model's output reaches this
/// type only after `super::prompt::parse_recommendations` has checked it, so
/// nothing above the parser has to wonder whether a slug is real.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recommendation {
    pub technique_slug: String,
    pub reason: String,
}

/// Where an answer came from. Mirrors `pb::AssistantSource`, minus the zero
/// value the wire format can always produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantSource {
    Model,
    Fallback,
}

/// How many techniques one recommendation carries.
///
/// Three. It is a nudge towards the next session, and a person who wanted the
/// whole catalogue would have opened the catalogue.
pub const RECOMMENDATION_COUNT: usize = 3;

/// Model calls one person may make per UTC day.
///
/// Generous by design: the free tier gets a real taste of the assistant, and
/// falls back to the rules afterwards rather than hitting a wall (the business
/// plan's framing — the paywall is M8, not this). It is a spend ceiling, not a
/// product tier.
///
/// **The entitlement seam.** M8 makes this depend on the caller: a subscriber
/// gets a higher allowance, and the entitlement is read from the `users` row the
/// backend verified a `StoreKit` transaction against — never from a client
/// boolean. The change lands as a per-caller limit passed into
/// `super::repository::claim_daily_call`, which already takes one.
pub const DAILY_MODEL_CALLS: i32 = 25;

/// The output ceiling on a recommendation call.
///
/// Three slugs and three sentences fit comfortably; a model that keeps writing
/// is cut off, and the parser drops whatever the truncation mangled.
pub const RECOMMENDATION_MAX_TOKENS: i32 = 400;

/// The output ceiling on an explanation.
///
/// Larger than a recommendation because prose is the deliverable here, and
/// still small enough that one call cannot become expensive on its own.
pub const EXPLANATION_MAX_TOKENS: i32 = 700;
