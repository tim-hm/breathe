//! The answer when there is no model.
//!
//! Offline-first, applied on the server. The app is built so that a person with
//! no signal still gets a full session; the same promise has to survive the
//! model being down, over quota, or behind a tripped breaker — so these
//! functions produce a real answer from the catalogue and the profile, and the
//! response says `FALLBACK` so the client can be honest about which it got.
//!
//! Rules, not canned text pretending to be a model. The ranking is the person's
//! own goal ordering, which is the same signal the model is given, so the
//! fallback answer is a plainer version of the same judgement rather than a
//! different one.

use super::types::{RECOMMENDATION_COUNT, Recommendation, goal_phrase};
use crate::features::profile::types::{ExperienceLevel, ProfileSnapshot};
use crate::features::technique::types::Technique;

/// Techniques to try, ranked by the goals the person picked.
///
/// Their first goal first, in catalogue order within it, then their second, and
/// so on; then whatever is left in catalogue order, so the list is always full
/// even for somebody who picked one goal or none. Catalogue order is curated to
/// open on what a newcomer should try first, which makes it the right tiebreak.
pub fn recommendations(catalogue: &[Technique], profile: &ProfileSnapshot) -> Vec<Recommendation> {
    let mut ranked: Vec<&Technique> = catalogue.iter().collect();

    // A *stable* sort is what expresses the whole rule: techniques serving an
    // earlier goal come first, catalogue order survives within each goal, and
    // everything the person did not ask for keeps its curated order at the end.
    ranked.sort_by_key(|technique| {
        profile
            .goals
            .iter()
            .position(|goal| *goal == technique.goal)
            .unwrap_or(usize::MAX)
    });

    ranked
        .into_iter()
        .take(RECOMMENDATION_COUNT)
        .map(|technique| Recommendation {
            technique_slug: technique.slug.clone(),
            reason: reason(technique, profile),
        })
        .collect()
}

/// Why this technique, in one sentence.
///
/// Two shapes: one for a technique that serves a goal they named, one for a
/// technique that is simply a good place to start. Neither claims to be
/// personalised beyond what the profile actually says — the client is told this
/// came from the rules, and copy that oversold itself would make that flag a
/// lie.
fn reason(technique: &Technique, profile: &ProfileSnapshot) -> String {
    if profile.goals.contains(&technique.goal) {
        format!(
            "You said you want to {} — this is one of the ways in.",
            goal_phrase(technique.goal)
        )
    } else {
        format!(
            "A steady place to start, and it will help you {}.",
            goal_phrase(technique.goal)
        )
    }
}

/// Why a technique works, from what the catalogue already knows.
///
/// The catalogue's own summary carries the mechanism — it is curated reference
/// data written for exactly this purpose — so the fallback frames it for the
/// person's experience level and adds the safety note where there is one, rather
/// than inventing physiology this server has no business asserting.
pub fn explanation(technique: &Technique, profile: &ProfileSnapshot) -> String {
    let mut text = format!("{}\n\n", technique.summary);

    // `None` reads as "new" here, unlike everywhere else this enum is decoded:
    // the beginner's advice is the safe advice, and somebody who has not been
    // asked is exactly who should get it.
    text.push_str(match profile.experience_level {
        Some(ExperienceLevel::Regular) => {
            "You practise already, so treat the counts as a floor rather than a target: \
             the pattern matters more than the numbers, and it is worth staying with one \
             exercise long enough to notice what it does."
        }
        Some(ExperienceLevel::Occasional) => {
            "You have done some of this before. The counts are a starting point — if a \
             hold feels sharp, shorten it; the breathing works while you are still \
             learning it."
        }
        Some(ExperienceLevel::New) | None => {
            "If you are new to this, do not chase the counts. Breathe through the nose, \
             let the belly move before the chest, and stop if anything feels sharp."
        }
    });

    if !technique.safety_note.is_empty() {
        text.push_str("\n\n");
        text.push_str(&technique.safety_note);
    }

    text
}
