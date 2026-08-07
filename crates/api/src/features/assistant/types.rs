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

/// The physiological ranges a client-supplied health summary must sit inside.
///
/// Wide on purpose: these are not clinical reference ranges but the bounds of
/// what a wrist sensor could plausibly have measured on a living wearer — a
/// resting heart rate outside 25–150 bpm, or an SDNN outside 1–300 ms, is a
/// sensor artefact or a fabricated request, and either way not something the
/// coach should be reasoning from. The trend windows are the widest week-over-
/// baseline shift a genuine wearer could show; anything larger reads as a
/// different person wearing the watch.
const RESTING_HR_BPM_RANGE: std::ops::RangeInclusive<i32> = 25..=150;
const RESTING_HR_TREND_BPM_RANGE: std::ops::RangeInclusive<i32> = -40..=40;
const HRV_SDNN_MS_RANGE: std::ops::RangeInclusive<i32> = 1..=300;
const HRV_SDNN_TREND_MS_RANGE: std::ops::RangeInclusive<i32> = -150..=150;

/// The coarse heart trends a request carried, after clamping — what
/// `prompt::health_lines` renders and nothing else reads.
///
/// Special-category data under GDPR Art. 9, which shapes this type twice over.
/// It is built per request and dropped with it — nothing here is ever written
/// to the database. And it deliberately derives no `Debug` and no `Display`,
/// so no `tracing` call, panic message, or format string can render it: a
/// value that cannot be formatted cannot be logged by accident, which turns
/// "health values never reach the log" from a review rule into a compile
/// error.
///
/// Each metric is a rounded 7-day mean and an optional delta against the
/// weeks before it, mirroring the phone's `HealthSnapshot`. A trend never
/// appears without its mean — a delta against a mean that was dropped would be
/// a number with no referent.
pub struct HealthContext {
    pub resting_hr_bpm: Option<i32>,
    pub resting_hr_trend_bpm: Option<i32>,
    pub hrv_sdnn_ms: Option<i32>,
    pub hrv_sdnn_trend_ms: Option<i32>,
}

impl HealthContext {
    /// The context these four wire fields support, clamped field by field.
    ///
    /// Out-of-range values drop the field and never the request — the request
    /// also carries the question, and a broken sensor should not silence the
    /// coach. A trend whose mean was dropped falls with it, and a context left
    /// with no mean at all is `None`: absent and all-dropped must be
    /// indistinguishable downstream, because both must render no HEALTH block.
    pub fn clamped(
        resting_hr_bpm: Option<i32>,
        resting_hr_trend_bpm: Option<i32>,
        hrv_sdnn_ms: Option<i32>,
        hrv_sdnn_trend_ms: Option<i32>,
    ) -> Option<Self> {
        let (resting_hr_bpm, resting_hr_trend_bpm) = clamped_metric(
            resting_hr_bpm,
            resting_hr_trend_bpm,
            RESTING_HR_BPM_RANGE,
            RESTING_HR_TREND_BPM_RANGE,
        );
        let (hrv_sdnn_ms, hrv_sdnn_trend_ms) = clamped_metric(
            hrv_sdnn_ms,
            hrv_sdnn_trend_ms,
            HRV_SDNN_MS_RANGE,
            HRV_SDNN_TREND_MS_RANGE,
        );

        (resting_hr_bpm.is_some() || hrv_sdnn_ms.is_some()).then_some(Self {
            resting_hr_bpm,
            resting_hr_trend_bpm,
            hrv_sdnn_ms,
            hrv_sdnn_trend_ms,
        })
    }
}

/// One metric through the clamp: the mean survives only inside its range, and
/// the trend survives only inside its own range *and* alongside a surviving
/// mean — the drop-with-its-mean coupling lives here so a metric added later
/// cannot forget it.
fn clamped_metric(
    mean: Option<i32>,
    trend: Option<i32>,
    mean_range: std::ops::RangeInclusive<i32>,
    trend_range: std::ops::RangeInclusive<i32>,
) -> (Option<i32>, Option<i32>) {
    let mean = mean.filter(|value| mean_range.contains(value));
    (
        mean,
        mean.and(trend.filter(|value| trend_range.contains(value))),
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
/// One shared pool for everything the model does. A recommendation, an
/// explanation, and a chat turn each claim one call, because each is one paid
/// completion — separate pools would be three ceilings to tune and a person
/// arguing with the wrong one. Fifty covers a real conversation on top of the
/// browsing the old ceiling of 25 was sized for: chat charges per turn, and a
/// ceiling that a genuine chat could exhaust in one sitting would make the
/// coach's best feature the way to lose the coach for the day (raised 25 → 50
/// with the conversational coach, product decision 2026-08-07).
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
        Tier::Coach => Some(50),
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

/// The output ceiling on one chat reply.
///
/// The explanation's ceiling, for the explanation's reason: a conversational
/// answer is a few short paragraphs, and anything longer is a lecture in a
/// chat window.
pub const CHAT_MAX_TOKENS: i32 = 700;

/// The most history turns one chat call reads, keeping the newest.
///
/// Truncation is silent — the person is mid-conversation, and "your transcript
/// is long" is not an answer to what they asked. Twenty turns is ten
/// exchanges, which is more context than a coaching answer ever draws on, and
/// it bounds the per-call input spend the way `CHAT_MAX_TOKENS` bounds the
/// output.
pub const MAX_CHAT_TURNS: usize = 20;

/// The longest message — new or replayed as history — one chat call accepts,
/// in characters.
///
/// A bound rather than a truncation, unlike [`MAX_CHAT_TURNS`]: cutting a
/// message mid-sentence would have the coach answer something the person did
/// not say, so an over-long one is `INVALID_ARGUMENT` and the client keeps its
/// composer honest instead. Sized like the intent note's bound — generous for
/// typing, useless for wholesale prompt smuggling.
pub const MAX_CHAT_MESSAGE_CHARS: usize = 1000;

#[cfg(test)]
mod tests {
    use super::*;

    /// In-range values pass through untouched, trends included.
    #[test]
    fn a_plausible_context_survives_clamping_whole() {
        let context = HealthContext::clamped(Some(62), Some(4), Some(45), Some(-6))
            .expect("a plausible context is kept");

        assert_eq!(context.resting_hr_bpm, Some(62));
        assert_eq!(context.resting_hr_trend_bpm, Some(4));
        assert_eq!(context.hrv_sdnn_ms, Some(45));
        assert_eq!(context.hrv_sdnn_trend_ms, Some(-6));
    }

    /// The bounds are inclusive: a value on either edge is evidence, and
    /// clamping it away would make the documented range a lie by one unit.
    #[test]
    fn the_range_edges_are_kept() {
        let low = HealthContext::clamped(Some(25), Some(-40), Some(1), Some(-150))
            .expect("the low edges are in range");
        assert_eq!(low.resting_hr_bpm, Some(25));
        assert_eq!(low.resting_hr_trend_bpm, Some(-40));
        assert_eq!(low.hrv_sdnn_ms, Some(1));
        assert_eq!(low.hrv_sdnn_trend_ms, Some(-150));

        let high = HealthContext::clamped(Some(150), Some(40), Some(300), Some(150))
            .expect("the high edges are in range");
        assert_eq!(high.resting_hr_bpm, Some(150));
        assert_eq!(high.resting_hr_trend_bpm, Some(40));
        assert_eq!(high.hrv_sdnn_ms, Some(300));
        assert_eq!(high.hrv_sdnn_trend_ms, Some(150));
    }

    /// An implausible value drops its own field and nothing else — the request
    /// still carries a question, and one broken sensor must not silence the
    /// rest of the summary.
    #[test]
    fn an_implausible_value_drops_only_its_field() {
        let context = HealthContext::clamped(Some(300), Some(4), Some(45), None)
            .expect("the surviving metric keeps the context alive");

        assert_eq!(context.resting_hr_bpm, None);
        assert_eq!(context.hrv_sdnn_ms, Some(45));
    }

    /// A trend is a delta against its own mean, so a dropped mean takes the
    /// trend with it even when the trend itself is in range.
    #[test]
    fn a_trend_falls_with_its_mean() {
        let context = HealthContext::clamped(Some(300), Some(4), Some(45), Some(-6))
            .expect("the HRV metric survives");

        assert_eq!(context.resting_hr_bpm, None);
        assert_eq!(
            context.resting_hr_trend_bpm, None,
            "a delta against a dropped mean is a number with no referent"
        );
        assert_eq!(context.hrv_sdnn_trend_ms, Some(-6));
    }

    /// An out-of-range trend drops alone; its mean is independent evidence.
    #[test]
    fn an_implausible_trend_leaves_its_mean() {
        let context = HealthContext::clamped(Some(62), Some(90), Some(45), Some(200))
            .expect("both means survive");

        assert_eq!(context.resting_hr_bpm, Some(62));
        assert_eq!(context.resting_hr_trend_bpm, None);
        assert_eq!(context.hrv_sdnn_ms, Some(45));
        assert_eq!(context.hrv_sdnn_trend_ms, None);
    }

    /// A context with no surviving mean is no context at all — downstream must
    /// not be able to tell "sent nothing" from "sent nothing usable".
    #[test]
    fn a_context_with_no_surviving_mean_is_none() {
        assert!(HealthContext::clamped(None, None, None, None).is_none());
        assert!(HealthContext::clamped(Some(999), Some(4), Some(0), Some(-6)).is_none());
        assert!(
            HealthContext::clamped(None, Some(4), None, Some(-6)).is_none(),
            "trends alone carry no mean to anchor them"
        );
    }
}
