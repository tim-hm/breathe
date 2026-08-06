//! The assistant's domain vocabulary, and the numbers that bound what it costs.
//!
//! The prose here — what a goal is called, what an experience level is called —
//! is shared by the prompt and by the rule-based fallback on purpose: the
//! assistant's words for a goal should be the same whether a model or this
//! server wrote the sentence around them.

use crate::features::profile::types::ExperienceLevel;
use crate::features::technique::types::TechniqueGoal;

/// What a goal is called in prose.
///
/// Shared with `super::fallback`, which writes the rule-based reasons: the
/// assistant's vocabulary for a goal should be the same whether a model or this
/// server wrote the sentence.
pub const fn goal_phrase(goal: TechniqueGoal) -> &'static str {
    match goal {
        TechniqueGoal::Calm => "settle in the moment",
        TechniqueGoal::Sleep => "wind down towards sleep",
        TechniqueGoal::Energy => "raise their energy",
        TechniqueGoal::Reset => "reset after a spike",
        TechniqueGoal::Focus => "hold their focus",
    }
}

/// What an experience level is called in prose. `None` is a real state — nobody
/// has been asked — and reads as such rather than as a beginner.
pub const fn experience_phrase(level: Option<ExperienceLevel>) -> &'static str {
    match level {
        Some(ExperienceLevel::New) => "new to breathwork",
        Some(ExperienceLevel::Occasional) => "has tried it, without a routine",
        Some(ExperienceLevel::Regular) => "practises regularly",
        None => "unknown — they have not been asked",
    }
}

/// The separator between a slug and its reason in a model's reply.
///
/// A pipe rather than a colon or a comma, because both of those occur inside
/// the sentence on the right and neither occurs in a slug — so `split_once`
/// cannot be fooled by ordinary English. Shared by the instruction that asks
/// for this shape and the parser that reads it: two copies could disagree, and
/// the disagreement would look exactly like a model that stopped following
/// instructions.
pub const FIELD_SEPARATOR: char = '|';

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
