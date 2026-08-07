//! Where a model's output stops being text and becomes slugs this server is
//! willing to name.
//!
//! Its own file rather than the back half of `super::prompt`, because the two
//! answer different questions: that module decides what to ask for, and this one
//! decides what to believe. Only this one is load-bearing for safety.

use super::types::{FIELD_SEPARATOR, RECOMMENDATION_COUNT, Recommendation};
use crate::features::technique::types::{Technique, resolve};

/// The longest reason kept. A model asked for one sentence that writes five has
/// misunderstood, and a paragraph in a list row is a layout bug on every client.
const MAX_REASON_CHARS: usize = 220;

/// Turns a model's reply into slugs this server is prepared to name.
///
/// The guard, not a formality. Everything is dropped that is not a
/// `slug | reason` line naming a technique the catalogue actually holds:
/// an invented slug, a plausible near-miss, a preamble sentence, a numbered
/// list. Duplicates collapse, because a model that recommended the same
/// technique twice has given one recommendation.
///
/// An empty result is the expected answer to a reply that was entirely
/// unusable, and the caller reads it as "fall back to the rules" — so no
/// malformed reply can reach a client, and no unvalidated text can be mistaken
/// for a slug.
pub fn parse_recommendations(reply: &str, catalogue: &[Technique]) -> Vec<Recommendation> {
    let mut recommendations: Vec<Recommendation> = Vec::new();

    for line in reply.lines() {
        let Some((slug, reason)) = line.split_once(FIELD_SEPARATOR) else {
            continue;
        };

        let slug = slug.trim();
        let reason = reason.trim();

        if reason.is_empty() || reason.chars().count() > MAX_REASON_CHARS {
            continue;
        }

        // The catalogue is the authority. A slug is kept because a row has it,
        // never because it looks like one.
        if resolve(catalogue, slug).is_none() {
            continue;
        }

        if recommendations
            .iter()
            .any(|kept| kept.technique_slug == slug)
        {
            continue;
        }

        recommendations.push(Recommendation {
            technique_slug: slug.to_owned(),
            reason: reason.to_owned(),
        });

        if recommendations.len() == RECOMMENDATION_COUNT {
            break;
        }
    }

    recommendations
}

#[cfg(test)]
mod tests {
    use super::*;
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
            technique("physiological-sigh", TechniqueGoal::Reset),
        ]
    }

    /// The whole reason the parser exists: a model that names a technique the
    /// app does not have must not be able to put that name in front of anyone.
    /// Without the catalogue check the client navigates to a slug it cannot
    /// resolve, which is a dead row rather than a visible failure.
    #[test]
    fn an_invented_slug_is_dropped() {
        let parsed = parse_recommendations(
            "moon-breathing | Invented outright.\nbox-breathing | Real one.",
            &catalogue(),
        );

        assert_eq!(
            parsed,
            vec![Recommendation {
                technique_slug: "box-breathing".to_owned(),
                reason: "Real one.".to_owned(),
            }]
        );
    }

    /// A reply that is entirely prose yields nothing, which is what tells the
    /// service to fall back. Returning the prose as a slug is the failure this
    /// pins.
    #[test]
    fn an_unusable_reply_yields_nothing() {
        for reply in [
            "Here are my recommendations for you!",
            "1. box-breathing - it is calming",
            "",
            "box-breathing |    ",
        ] {
            assert!(
                parse_recommendations(reply, &catalogue()).is_empty(),
                "`{reply}` should parse to nothing"
            );
        }
    }

    /// Chattiness around the lines is not a failure — the lines are still
    /// there, and a preamble the model could not resist is not worth discarding
    /// a good answer over.
    #[test]
    fn surrounding_prose_is_ignored() {
        let parsed = parse_recommendations(
            "Sure! Here you go:\n\n\
             box-breathing | Equal counts give you something to hold on to.\n\
             four-seven-eight | The long exhale is doing the work.\n\n\
             Let me know if you want more.",
            &catalogue(),
        );

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].technique_slug, "box-breathing");
        assert_eq!(parsed[1].technique_slug, "four-seven-eight");
    }

    /// A repeated technique is one recommendation, and the list stays bounded
    /// however many lines arrive — a client renders this list, and a model that
    /// returned thirty would push everything else off the screen.
    #[test]
    fn duplicates_collapse_and_the_list_stays_bounded() {
        let mut reply = String::from("box-breathing | First.\nbox-breathing | Again.\n");
        for _ in 0..10 {
            reply.push_str("four-seven-eight | Sleep.\nphysiological-sigh | Reset.\n");
        }

        let parsed = parse_recommendations(&reply, &catalogue());

        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].reason, "First.");
    }
}
