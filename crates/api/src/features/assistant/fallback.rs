//! The answer when there is no model.
//!
//! Offline-first, applied on the server. The app is built so that a person with
//! no signal still gets a full session; the same promise has to survive the
//! model being down, over quota, or behind a tripped breaker — so these
//! functions produce a real answer from the catalogue, the profile, and the
//! practice snapshot, and the response says `FALLBACK` so the client can be
//! honest about which it got.
//!
//! Rules, not canned text pretending to be a model. The ranking is the person's
//! own goal ordering, which is the same signal the model is given, so the
//! fallback answer is a plainer version of the same judgement rather than a
//! different one.

use super::types::{RECOMMENDATION_COUNT, Recommendation, bolt_phrase, goal_phrase};
use crate::features::journey::bolt::types::BoltSnapshot;
use crate::features::journey::sessions::types::PracticeSnapshot;
use crate::features::profile::types::{ExperienceLevel, ProfileSnapshot};
use crate::features::technique::types::{Technique, TechniqueGoal, resolve};

/// Techniques to try, ranked by the goals the person picked.
///
/// Their first goal first, in catalogue order within it, then their second, and
/// so on; then whatever is left in catalogue order, so the list is always full
/// even for somebody who picked one goal or none. Catalogue order is curated to
/// open on what a newcomer should try first, which makes it the right tiebreak.
///
/// The practice snapshot buys the one history-aware judgement the rules can
/// make honestly: when the first goal has gone unpractised while something else
/// has not, the lead reason says so instead of repeating the goal back.
pub fn recommendations(
    catalogue: &[Technique],
    profile: &ProfileSnapshot,
    practice: &PracticeSnapshot,
) -> Vec<Recommendation> {
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

    let mut list: Vec<Recommendation> = ranked
        .into_iter()
        .take(RECOMMENDATION_COUNT)
        .map(|technique| Recommendation {
            technique_slug: technique.slug.clone(),
            reason: reason(technique, profile),
        })
        .collect();

    if let (Some(lead), Some((stated, practised))) =
        (list.first_mut(), goal_gap(catalogue, profile, practice))
    {
        lead.reason = format!(
            "You've been practising to {}, but you said you want to {} — start here.",
            goal_phrase(practised),
            goal_phrase(stated)
        );
    }

    list
}

/// The one judgement that watches the person's data: their first goal has had
/// strictly zero recent minutes while resolvable practice went somewhere else.
/// Returns `(stated, practised)`, or `None` in every other shape — no goals,
/// the first goal already practised, or nothing resolvable to contrast it
/// with.
///
/// Reads only the snapshot's named techniques, so a goal practised entirely in
/// the truncated tail can look neglected; the tail is one-offs by
/// construction, which is as close to "not practising it" as makes no
/// difference to the copy.
fn goal_gap(
    catalogue: &[Technique],
    profile: &ProfileSnapshot,
    practice: &PracticeSnapshot,
) -> Option<(TechniqueGoal, TechniqueGoal)> {
    let stated = *profile.goals.first()?;
    let goal_of = |slug: &str| resolve(catalogue, slug).map(|technique| technique.goal);

    if practice
        .by_technique
        .iter()
        .any(|entry| entry.minutes > 0 && goal_of(&entry.technique_slug) == Some(stated))
    {
        return None;
    }

    // Busiest first, so the goal named is the one their sessions actually went
    // to.
    let practised = practice
        .by_technique
        .iter()
        .filter(|entry| entry.minutes > 0)
        .find_map(|entry| goal_of(&entry.technique_slug).filter(|goal| *goal != stated))?;

    Some((stated, practised))
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
/// person's experience level, reads their BOLT history where one exists, and
/// adds the safety note where there is one, rather than inventing physiology
/// this server has no business asserting.
pub fn explanation(
    technique: &Technique,
    profile: &ProfileSnapshot,
    bolt: Option<&BoltSnapshot>,
) -> String {
    let mut text = format!("{}\n\n", technique.summary);

    // `None` reads as "new" here, unlike everywhere else this enum is decoded:
    // the beginner's advice is the safe advice, and somebody who has not been
    // asked is exactly who should get it.
    text.push_str(match profile.experience_level {
        Some(ExperienceLevel::Regular) => {
            "You practise already, so treat the counts as a floor rather than a target: \
             the pattern matters more than the numbers, and it is worth staying with one \
             technique long enough to notice what it does."
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

    if let Some(bolt) = bolt {
        text.push_str("\n\n");
        text.push_str(&bolt_phrase(bolt));
    }

    if !technique.safety_note.is_empty() {
        text.push_str("\n\n");
        text.push_str(&technique.safety_note);
    }

    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::features::journey::sessions::types::{PRACTICE_WINDOW_DAYS, TechniquePractice};
    use crate::features::technique::types::TechniqueGoal;

    fn technique(slug: &str, goal: TechniqueGoal) -> Technique {
        Technique {
            slug: slug.to_owned(),
            name: slug.to_owned(),
            summary: "a summary".to_owned(),
            safety_note: String::new(),
            goal,
        }
    }

    fn catalogue() -> Vec<Technique> {
        vec![
            technique("box-breathing", TechniqueGoal::Calm),
            technique("four-seven-eight", TechniqueGoal::Sleep),
            technique("coffee-breath", TechniqueGoal::Energy),
        ]
    }

    fn profile(goals: Vec<TechniqueGoal>) -> ProfileSnapshot {
        ProfileSnapshot {
            goals,
            experience_level: None,
            intent_note: String::new(),
            birth_year_band: None,
            gender: None,
        }
    }

    fn no_practice() -> PracticeSnapshot {
        PracticeSnapshot {
            window_days: u32::from(PRACTICE_WINDOW_DAYS),
            sessions: 0,
            minutes: 0,
            active_days: 0,
            by_technique: vec![],
            bolt: None,
        }
    }

    fn practice_of(slug: &str, sessions: u32, minutes: u32) -> PracticeSnapshot {
        PracticeSnapshot {
            sessions,
            minutes,
            active_days: 1,
            by_technique: vec![TechniquePractice {
                technique_slug: slug.to_owned(),
                sessions,
                minutes,
            }],
            ..no_practice()
        }
    }

    /// The history-aware sentence: sleep is the stated goal, calm is where the
    /// minutes went, so the lead reason names the gap instead of repeating the
    /// goal back — and the lead technique still serves the stated goal.
    #[test]
    fn an_unpractised_first_goal_gets_a_corrective_lead() {
        let list = recommendations(
            &catalogue(),
            &profile(vec![TechniqueGoal::Sleep]),
            &practice_of("box-breathing", 5, 12),
        );

        assert_eq!(list[0].technique_slug, "four-seven-eight");
        assert_eq!(
            list[0].reason,
            "You've been practising to settle in the moment, but you said you want to \
             wind down towards sleep — start here."
        );
        // Only the lead is corrective; the rest keep the ordinary shapes.
        assert!(list[1].reason.ends_with('.'));
        assert!(!list[1].reason.contains("start here"));
    }

    /// No practice at all means nothing to contrast, so nobody's first day
    /// opens with a correction.
    #[test]
    fn no_practice_means_no_correction() {
        let list = recommendations(
            &catalogue(),
            &profile(vec![TechniqueGoal::Sleep]),
            &no_practice(),
        );

        assert_eq!(
            list[0].reason,
            "You said you want to wind down towards sleep — this is one of the ways in."
        );
    }

    /// A first goal with any recent minutes is being practised, and correcting
    /// somebody who is doing the thing would make the copy a nag.
    #[test]
    fn a_practised_first_goal_is_left_alone() {
        let list = recommendations(
            &catalogue(),
            &profile(vec![TechniqueGoal::Sleep]),
            &practice_of("four-seven-eight", 2, 6),
        );

        assert!(!list[0].reason.contains("start here"));
    }

    /// A slug the catalogue cannot resolve proves nothing about their goals,
    /// so it neither triggers a correction nor is quoted anywhere.
    #[test]
    fn unresolvable_practice_does_not_correct() {
        let list = recommendations(
            &catalogue(),
            &profile(vec![TechniqueGoal::Sleep]),
            &practice_of("moon-breathing", 5, 12),
        );

        assert!(!list[0].reason.contains("start here"));
    }

    /// The BOLT sentence rides in the explanation exactly when a score exists,
    /// with the same bands the model is briefed with.
    #[test]
    fn the_explanation_reads_the_bolt_history_when_there_is_one() {
        let technique = technique("box-breathing", TechniqueGoal::Calm);
        let profile = profile(vec![]);

        let without = explanation(&technique, &profile, None);
        assert!(!without.contains("BOLT"));

        let with = explanation(
            &technique,
            &profile,
            Some(&BoltSnapshot {
                best: 32,
                latest: 15,
                count: 4,
            }),
        );
        assert!(with.contains("Your most recent breath-hold (BOLT) score was 15 seconds"));
        assert!(with.contains("room to build your CO2 tolerance"));
    }
}
