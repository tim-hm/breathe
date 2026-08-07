//! The assistant's domain vocabulary, and the numbers that bound what it costs.
//!
//! The prose here — what a goal is called, what an experience level is called —
//! is shared by the prompt and by the rule-based fallback on purpose: the
//! assistant's words for a goal should be the same whether a model or this
//! server wrote the sentence around them.

use crate::features::entitlement::types::Tier;
use crate::features::journey::bolt::types::BoltSnapshot;
use crate::features::profile::types::{BirthYearBand, ExperienceLevel, Gender};
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

/// What a birth-year band is called in prose. Decade coarseness is deliberate —
/// the model calibrates a breath-test reading with it, and a finer age would
/// sharpen nothing but the privacy cost.
pub const fn band_phrase(band: BirthYearBand) -> &'static str {
    match band {
        BirthYearBand::BornBefore1960 => "born before 1960",
        BirthYearBand::Born1960s => "born in the 1960s",
        BirthYearBand::Born1970s => "born in the 1970s",
        BirthYearBand::Born1980s => "born in the 1980s",
        BirthYearBand::Born1990s => "born in the 1990s",
        BirthYearBand::Born2000s => "born in the 2000s",
        BirthYearBand::Born2010OrLater => "born in or after 2010",
    }
}

/// What a gender is called in prose. "Rather not say" is `None` on the
/// snapshot and never reaches this function — absence is expressed by writing
/// no line at all, not by a phrase.
pub const fn gender_phrase(gender: Gender) -> &'static str {
    match gender {
        Gender::Female => "female",
        Gender::Male => "male",
        Gender::NonBinary => "non-binary",
    }
}

/// The coarse BOLT bands the assistant reasons with, as the lower edge of each
/// band in seconds.
///
/// Following the published Oxygen Advantage bands (Patrick McKeown, *The
/// Oxygen Advantage*, 2015): under 10 seconds means breathing is very easily
/// unsettled, 10–20 leaves clear room to build CO2 tolerance, 20–30 is a solid
/// base, 30–40 is strong, and 40 is the programme's target. One set of numbers
/// for the model's briefing in `prompt::catalogue_prefix` and the fallback's
/// [`bolt_phrase`], so the two voices cannot drift apart.
pub const BOLT_BAND_BUILDING: u32 = 10;
pub const BOLT_BAND_SOLID: u32 = 20;
pub const BOLT_BAND_STRONG: u32 = 30;
pub const BOLT_BAND_TARGET: u32 = 40;

/// One sentence reading a BOLT history, for the rule-based fallback.
///
/// The same coarse bands the model is briefed with, in the same second person
/// the rest of the fallback speaks. It describes, and points at practice as the
/// lever — never a diagnosis, and never a number the person did not measure
/// themselves.
pub fn bolt_phrase(bolt: &BoltSnapshot) -> String {
    let reading = match bolt.latest {
        ..BOLT_BAND_BUILDING => {
            "your breathing is still easily unsettled, so keep sessions short and gentle"
        }
        BOLT_BAND_BUILDING..BOLT_BAND_SOLID => {
            "there is clear room to build your CO2 tolerance, and steady practice is what builds it"
        }
        BOLT_BAND_SOLID..BOLT_BAND_STRONG => "a solid base to build on",
        BOLT_BAND_STRONG..BOLT_BAND_TARGET => "a strong score, and worth maintaining",
        BOLT_BAND_TARGET.. => "an excellent score — your breathing is well trained",
    };

    format!(
        "Your most recent breath-hold (BOLT) score was {} seconds — {reading}.",
        bolt.latest
    )
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

/// Model calls one person may make per UTC day, or `None` for a tier that does
/// not buy the model at all.
///
/// The language model *is* Breathe Coach — it is the only thing in the app with
/// a marginal cost, and the only reason the top tier exists. So the answer is
/// `None` below it, and a ceiling above it.
///
/// **No free taste, deliberately.** M8's first shape gave everybody three calls
/// a day, which made sense while the subscription was one $4.99 yearly product
/// and the model was a bonus. It stops making sense now: an unbounded daily
/// spend against every install is the whole margin of a £0.99 Plus tier, and it
/// gives away the one thing Coach sells. Nobody hits a wall for it — every
/// caller below Coach gets the rule-based answer flagged `FALLBACK`, which is
/// the same answer everybody gets offline and a genuinely good one.
///
/// Read from the caller's `users` row, never from anything a request carries.
pub const fn daily_model_calls(tier: Tier) -> Option<i32> {
    match tier {
        Tier::Free | Tier::Plus => None,
        Tier::Coach => Some(25),
    }
}

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
