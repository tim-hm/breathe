//! Seeds the technique catalogue and the breathing foundations.
//!
//! Both are curated reference data, not user content, so they live in code and
//! are reconciled into the database on every run. Editing a summary here and
//! re-running `mise run migrate` is the supported way to change them.
//!
//! Queries in this module are runtime `sqlx::query`, not the compile-time-checked
//! macros used in `crates/api`. This is the one crate that runs *before* the
//! schema exists, so it cannot depend on a prepared cache that could only have
//! been generated against a database this binary is responsible for creating.

use anyhow::{Context, Result};
use sqlx::PgPool;

/// One phase: its kind, the curated default, and the range a dial may move it
/// within.
struct PhaseSeed {
    /// Matches a label of the `phase_kind` Postgres enum.
    kind: &'static str,
    duration_ms: i32,
    min_duration_ms: i32,
    max_duration_ms: i32,
}

/// A run of cycles sharing one phase pattern.
struct StageSeed {
    phases: &'static [PhaseSeed],
    cycles: i32,
    /// Whether the person ends this stage rather than the clock.
    open_ended: bool,
}

/// One technique and the session it describes.
struct TechniqueSeed {
    slug: &'static str,
    name: &'static str,
    summary: &'static str,
    /// The caution this technique carries, empty where it carries none. Shown
    /// while breathing, not only while choosing.
    safety_note: &'static str,
    /// Matches a label of the `technique_goal` Postgres enum.
    goal: &'static str,
    stages: &'static [StageSeed],
    /// How many times a default session repeats the whole stage list. Curated
    /// per technique, and one for everything that is a single cycle repeated —
    /// rounds only earn their name in a staged protocol.
    recommended_rounds: i32,
}

/// A phase with the dial range it may be moved within, inclusive.
///
/// A range of a single point means the phase is not adjustable, which is the
/// honest description of a hold the person ends themselves.
const fn phase(kind: &'static str, duration_ms: i32, dial: (i32, i32)) -> PhaseSeed {
    PhaseSeed {
        kind,
        duration_ms,
        min_duration_ms: dial.0,
        max_duration_ms: dial.1,
    }
}

const fn stage(phases: &'static [PhaseSeed], cycles: i32) -> StageSeed {
    StageSeed {
        phases,
        cycles,
        open_ended: false,
    }
}

/// A stage the clock does not end. One cycle by definition: repeating a hold
/// the person is already in charge of ending means nothing.
const fn open_ended_stage(phases: &'static [PhaseSeed]) -> StageSeed {
    StageSeed {
        phases,
        cycles: 1,
        open_ended: true,
    }
}

/// Array order is presentation order — `sort_order` is the index, so reordering
/// this list is the only edit needed to reorder the catalogue. Techniques are
/// grouped by goal in the order a newcomer meets them: calm first, the fast and
/// contraindicated ones well down the list.
const TECHNIQUES: &[TechniqueSeed] = &[
    TechniqueSeed {
        slug: "box-breathing",
        name: "Box Breathing",
        summary: "Four equal counts — in, hold, out, hold. The most forgiving place to start, \
                  and the one to reach for before something stressful rather than during it.",
        safety_note: "",
        goal: "CALM",
        stages: &[stage(
            &[
                phase("INHALE", 4000, (3000, 8000)),
                phase("HOLD_IN", 4000, (2000, 8000)),
                phase("EXHALE", 4000, (3000, 8000)),
                phase("HOLD_OUT", 4000, (2000, 8000)),
            ],
            // Eight sixteen-second cycles — a little over two minutes, the
            // length a first session should be to feel worth doing and still
            // fit in a gap between meetings.
            8,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "coherent-breathing",
        name: "Coherent Breathing",
        summary: "One long breath in, one just as long out — about five and a half breaths a \
                  minute. No holds and nothing to count: at this pace heart rate and breath fall \
                  into step on their own, which is the whole of the technique.",
        safety_note: "",
        goal: "CALM",
        stages: &[stage(
            // The resonance range sits near six breaths a minute for most
            // people and is worth exploring by feel — hence a dial that reaches
            // four seconds (7.5/min) and seven (4.3/min) either side.
            &[
                phase("INHALE", 5500, (4000, 7000)),
                phase("EXHALE", 5500, (4000, 7000)),
            ],
            // Just under five minutes. Resonance work is studied in bouts of
            // five to ten, and five is the one people actually come back to.
            27,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "four-seven-eight",
        name: "4-7-8 Breathing",
        summary: "Inhale for four, hold for seven, exhale for eight. The long exhale is doing the \
                  work; if the hold feels strained, shorten all three and keep the ratio.",
        safety_note: "Meant to make you drowsy. Somewhere you can stay put, not behind a wheel.",
        goal: "SLEEP",
        stages: &[stage(
            &[
                phase("INHALE", 4000, (3000, 6000)),
                phase("HOLD_IN", 7000, (4000, 10000)),
                phase("EXHALE", 8000, (6000, 12000)),
            ],
            // Four is the count the technique is taught with, and the count its
            // originator caps beginners at.
            4,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "extended-exhale",
        name: "Extended Exhale",
        summary: "In for four, out for six. The same lever 4-7-8 pulls — an out-breath longer \
                  than the in-breath — with no hold to strain against. Stretch the exhale towards \
                  eight when six stops feeling like enough.",
        safety_note: "Meant to make you drowsy. Somewhere you can stay put, not behind a wheel.",
        goal: "SLEEP",
        stages: &[stage(
            &[
                phase("INHALE", 4000, (3000, 5000)),
                // Six to eight is the range the evidence is gathered at, and the
                // one the summary invites people to walk up.
                phase("EXHALE", 6000, (6000, 8000)),
            ],
            // Twelve ten-second cycles: two minutes, long enough for the shift
            // to be noticeable and short enough to do in bed without deciding to.
            12,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "physiological-sigh",
        name: "Physiological Sigh",
        summary: "A full inhale, a second short sip of air on top, then a long slow exhale. \
                  One or two rounds is the whole technique — it works in seconds, not minutes.",
        safety_note: "",
        goal: "RESET",
        stages: &[stage(
            // Two consecutive INHALE phases, deliberately. The second sip
            // re-inflates collapsed alveoli, and it is a distinct beat the
            // client must cue separately — merging them into one long inhale
            // loses the technique.
            &[
                phase("INHALE", 1500, (1000, 2500)),
                phase("INHALE", 700, (500, 1200)),
                phase("EXHALE", 5000, (4000, 8000)),
            ],
            // The summary promises "one or two rounds"; three is the generous
            // end of that, and the technique loses its point when stretched
            // into a session.
            3,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "bellows-breath",
        name: "Bellows Breath",
        summary: "Rapid, forceful, equal inhales and exhales through the nose. A short bout is \
                  the whole dose — this one raises alertness in under a minute and has nothing \
                  more to give after that.",
        safety_note: "Sitting down only. Stop at the first sign of lightheadedness. Never in \
                      water, never while driving.",
        goal: "ENERGY",
        stages: &[stage(
            &[
                phase("INHALE", 1000, (700, 1500)),
                phase("EXHALE", 1000, (700, 1500)),
            ],
            // Twenty two-second breaths is forty seconds — a short bout, which
            // is the only kind this technique should be practised in.
            20,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "wim-hof-rounds",
        name: "Wim Hof-style Rounds",
        summary: "Thirty full, unforced breaths, then let the air go and wait — the hold after \
                  them is the point, and it lasts as long as it lasts. One deep breath in, held \
                  for fifteen seconds, closes each round. Popular, well described by people who \
                  practise it, and thinner on trial evidence than its reputation suggests.",
        safety_note: "Sitting or lying down, always. Never in water, never in the bath, never \
                      driving or standing — fast breathing can make you faint with no warning. \
                      Tingling in the hands and face is ordinary; dizziness means stop. Never \
                      push a hold to the limit: this app does not measure one.",
        goal: "ENERGY",
        stages: &[
            stage(
                &[
                    phase("INHALE", 1500, (1000, 2500)),
                    phase("EXHALE", 1500, (1000, 2500)),
                ],
                // Thirty is the count the protocol is described with, and the
                // bottom of the thirty-to-forty range people practise it at.
                30,
            ),
            // The retention. Its duration is what a settled practitioner tends
            // to reach, shown as a typical hold rather than a target — the
            // range is a single point because there is no dial here at all.
            open_ended_stage(&[phase("HOLD_OUT", 60000, (60000, 60000))]),
            stage(
                &[
                    phase("INHALE", 3000, (2000, 5000)),
                    phase("HOLD_IN", 15000, (10000, 20000)),
                    phase("EXHALE", 4000, (2000, 6000)),
                ],
                1,
            ),
        ],
        // Three rounds is the described protocol, and the count at which the
        // hold typically lengthens on its own — which is the reason to do more
        // than one.
        recommended_rounds: 3,
    },
    TechniqueSeed {
        slug: "long-box-breathing",
        name: "Long Box Breathing",
        summary: "Box breathing with longer sides — six counts each, or eight once six feels \
                  easy. The hold is what makes it a focus technique rather than a calming one: \
                  there is enough to keep track of that there is no room left to drift.",
        safety_note: "",
        goal: "FOCUS",
        stages: &[stage(
            &[
                phase("INHALE", 6000, (4000, 10000)),
                phase("HOLD_IN", 6000, (4000, 10000)),
                phase("EXHALE", 6000, (4000, 10000)),
                phase("HOLD_OUT", 6000, (4000, 10000)),
            ],
            // Six twenty-four-second cycles: two and a half minutes, the same
            // dose as box breathing at a pace that asks more of you.
            6,
        )],
        recommended_rounds: 1,
    },
    TechniqueSeed {
        slug: "alternate-nostril",
        name: "Alternate-Nostril Breathing",
        summary: "Thumb closes the right nostril, ring finger the left. In through the left, out \
                  through the right, in through the right, out through the left — that sequence \
                  is one cycle, and the four beats on screen are its four breaths in order. A \
                  traditional practice with modest trial support and an unmistakable knack for \
                  holding attention.",
        safety_note: "",
        goal: "FOCUS",
        stages: &[stage(
            &[
                phase("INHALE", 4000, (3000, 6000)),
                phase("EXHALE", 6000, (4000, 8000)),
                phase("INHALE", 4000, (3000, 6000)),
                phase("EXHALE", 6000, (4000, 8000)),
            ],
            // Nine twenty-second cycles — three minutes, thirty-six breaths,
            // and the point at which the switching stops needing thought.
            9,
        )],
        recommended_rounds: 1,
    },
];

/// One question a beginner has, and the app's answer to it.
struct FoundationSeed {
    slug: &'static str,
    question: &'static str,
    answer: &'static str,
}

/// Array order is reading order, same as the catalogue. These are ordered the
/// way the questions occur to someone learning: what moves, what it goes
/// through, where to sit, what to do with your eyes.
const FOUNDATIONS: &[FoundationSeed] = &[
    FoundationSeed {
        slug: "belly-or-chest",
        question: "Belly or chest?",
        answer: "Belly, if you can. Rest a hand just below your ribs and let that be the hand \
                 that moves — the diaphragm does the work and the chest goes along with it. \
                 Chest breathing is not a mistake, only a shallower version of the same thing, \
                 and the belly comes with practice faster than you would expect.",
    },
    FoundationSeed {
        slug: "nose-or-mouth",
        question: "In through the nose?",
        answer: "Where you can. The nose filters and warms the air, picks up nitric oxide from \
                 the sinuses on the way past, and slows the breath down without you deciding to. \
                 It is genuinely hard at first if you are congested or used to breathing through \
                 your mouth — and it does get easier. Start with your mouth if you need to; the \
                 breathing still works while you are learning.",
    },
    FoundationSeed {
        slug: "how-to-exhale",
        question: "And out through what?",
        answer: "Nose or pursed lips, whichever you can keep going. Pursed lips — the shape for \
                 cooling a spoonful of soup — give you something to push against, which makes a \
                 long exhale much easier to hold onto. Most of the calming happens on the way \
                 out, so the extra length is worth a little effort.",
    },
    FoundationSeed {
        slug: "sitting-or-lying",
        question: "Sit or lie down?",
        answer: "Sit for anything alerting, lie down for anything meant to end in sleep. Upright \
                 with your feet on the floor keeps you from drifting off halfway; on your back \
                 the belly moves more freely and nothing has to hold you up. Fast-breathing \
                 techniques are seated or lying down every time — that one is not a suggestion.",
    },
    FoundationSeed {
        slug: "eyes-open-or-closed",
        question: "Eyes open or closed?",
        answer: "Closed is usually simpler: less to look at, less to think about. If closing them \
                 makes you uneasy, leave them open and rest your gaze on something dull a metre \
                 or two ahead. Watching the animation is the third option, and it is the one \
                 that makes the counting effortless.",
    },
];

pub async fn run(pool: &PgPool) -> Result<()> {
    let mut tx = pool
        .begin()
        .await
        .context("failed to open seed transaction")?;

    for (index, technique) in TECHNIQUES.iter().enumerate() {
        upsert_technique(&mut tx, index, technique).await?;
    }

    for (index, topic) in FOUNDATIONS.iter().enumerate() {
        sqlx::query(
            r"INSERT INTO foundation_topics (slug, question, answer, sort_order)
               VALUES ($1, $2, $3, $4)
               ON CONFLICT (slug) DO UPDATE SET
                 question = EXCLUDED.question,
                 answer = EXCLUDED.answer,
                 sort_order = EXCLUDED.sort_order",
        )
        .bind(topic.slug)
        .bind(topic.question)
        .bind(topic.answer)
        .bind(i32::try_from(index).context("foundations are impossibly many")?)
        .execute(&mut *tx)
        .await
        .with_context(|| format!("failed to upsert foundation topic `{}`", topic.slug))?;
    }

    tx.commit()
        .await
        .context("failed to commit seed transaction")?;
    tracing::info!(
        techniques = TECHNIQUES.len(),
        foundations = FOUNDATIONS.len(),
        "reference data seeded"
    );

    Ok(())
}

/// Writes one technique and replaces its stages wholesale.
async fn upsert_technique(
    tx: &mut sqlx::PgTransaction<'_>,
    index: usize,
    technique: &TechniqueSeed,
) -> Result<()> {
    // `id` is only consumed on first insert; on conflict the existing row keeps
    // its id, so reseeding never invalidates a reference held elsewhere.
    let id: String = sqlx::query_scalar(
        r"INSERT INTO techniques
                 (id, slug, name, summary, safety_note, goal, sort_order, recommended_rounds)
               VALUES ($1, $2, $3, $4, $5, $6::technique_goal, $7, $8)
               ON CONFLICT (slug) DO UPDATE SET
                 name = EXCLUDED.name,
                 summary = EXCLUDED.summary,
                 safety_note = EXCLUDED.safety_note,
                 goal = EXCLUDED.goal,
                 sort_order = EXCLUDED.sort_order,
                 recommended_rounds = EXCLUDED.recommended_rounds,
                 updated_at = now()
               RETURNING id",
    )
    .bind(cuid2::create_id())
    .bind(technique.slug)
    .bind(technique.name)
    .bind(technique.summary)
    .bind(technique.safety_note)
    .bind(technique.goal)
    .bind(i32::try_from(index).context("catalogue is impossibly large")?)
    .bind(technique.recommended_rounds)
    .fetch_one(&mut **tx)
    .await
    .with_context(|| format!("failed to upsert technique `{}`", technique.slug))?;

    // Replace rather than upsert: the session is an ordered list of ordered
    // lists, so a shorter edit would otherwise leave the trailing stages of the
    // previous version behind and lengthen the technique silently. The phases go
    // with them — their foreign key is the stage.
    sqlx::query("DELETE FROM technique_stages WHERE technique_id = $1")
        .bind(&id)
        .execute(&mut **tx)
        .await
        .with_context(|| format!("failed to clear stages for `{}`", technique.slug))?;

    for (ordinal, stage) in technique.stages.iter().enumerate() {
        let ordinal = i32::try_from(ordinal).context("session is impossibly long")?;

        sqlx::query(
            r"INSERT INTO technique_stages (technique_id, ordinal, cycles, open_ended)
               VALUES ($1, $2, $3, $4)",
        )
        .bind(&id)
        .bind(ordinal)
        .bind(stage.cycles)
        .bind(stage.open_ended)
        .execute(&mut **tx)
        .await
        .with_context(|| format!("failed to insert stage {ordinal} of `{}`", technique.slug))?;

        for (phase_ordinal, phase) in stage.phases.iter().enumerate() {
            sqlx::query(
                r"INSERT INTO technique_phases
                     (technique_id, stage_ordinal, ordinal, kind, duration_ms,
                      min_duration_ms, max_duration_ms)
                   VALUES ($1, $2, $3, $4::phase_kind, $5, $6, $7)",
            )
            .bind(&id)
            .bind(ordinal)
            .bind(i32::try_from(phase_ordinal).context("cycle is impossibly long")?)
            .bind(phase.kind)
            .bind(phase.duration_ms)
            .bind(phase.min_duration_ms)
            .bind(phase.max_duration_ms)
            .execute(&mut **tx)
            .await
            .with_context(|| {
                format!(
                    "failed to insert phase {phase_ordinal} of stage {ordinal} of `{}`",
                    technique.slug
                )
            })?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The only slug the client is allowed to know about by name, and the only
    /// technique in the catalogue that has stages worth calling stages.
    const WIM_HOF: &str = "wim-hof-rounds";

    /// A technique with no stages — or a stage with no phases — would leave the
    /// client with an empty animation loop and nothing to advance through. The
    /// service rejects both at read time; catching it here names the technique.
    #[test]
    fn every_technique_is_a_playable_session() {
        for technique in TECHNIQUES {
            assert!(
                !technique.stages.is_empty(),
                "`{}` has no stages",
                technique.slug
            );
            assert!(
                technique.recommended_rounds > 0,
                "`{}` recommends no rounds",
                technique.slug
            );

            for (ordinal, stage) in technique.stages.iter().enumerate() {
                assert!(
                    !stage.phases.is_empty(),
                    "stage {ordinal} of `{}` has no phases",
                    technique.slug
                );
                assert!(
                    stage.cycles > 0,
                    "stage {ordinal} of `{}` plays no cycles",
                    technique.slug
                );
            }
        }
    }

    /// `slug` is the key the iOS client pins its artwork and haptics to, and the
    /// upsert is keyed on it — a duplicate would make the seed order decide
    /// which definition wins.
    #[test]
    fn slugs_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for technique in TECHNIQUES {
            assert!(
                seen.insert(technique.slug),
                "duplicate slug `{}`",
                technique.slug
            );
        }
    }

    /// The `technique_phases_duration_within_range` CHECK in `0003` would reject
    /// these at write time, and a client rendering a dial from a range that does
    /// not contain its own starting value has nowhere to put the handle.
    #[test]
    fn every_dial_range_contains_its_default() {
        for technique in TECHNIQUES {
            for stage in technique.stages {
                for phase in stage.phases {
                    assert!(
                        phase.min_duration_ms > 0,
                        "`{}` has a non-positive {} minimum",
                        technique.slug,
                        phase.kind
                    );
                    assert!(
                        phase.min_duration_ms <= phase.duration_ms
                            && phase.duration_ms <= phase.max_duration_ms,
                        "`{}` has a {} default of {}ms outside its {}–{}ms range",
                        technique.slug,
                        phase.kind,
                        phase.duration_ms,
                        phase.min_duration_ms,
                        phase.max_duration_ms
                    );
                }
            }
        }
    }

    /// An open-ended stage stops the session clock until the person taps, so one
    /// seeded by accident would strand them on a screen that never advances. The
    /// retention in the Wim Hof-style protocol is the only place it belongs, and
    /// it is a single emptied-lung hold — anything else marked open-ended is a
    /// mistake, and so is the retention losing the flag.
    #[test]
    fn only_the_wim_hof_retention_is_open_ended() {
        for technique in TECHNIQUES {
            for (ordinal, stage) in technique.stages.iter().enumerate() {
                if !stage.open_ended {
                    continue;
                }

                assert_eq!(
                    technique.slug, WIM_HOF,
                    "`{}` has an unexpected open-ended stage",
                    technique.slug
                );
                assert_eq!(
                    stage.phases.len(),
                    1,
                    "the open-ended stage of `{}` is more than one hold",
                    technique.slug
                );
                assert_eq!(stage.phases[0].kind, "HOLD_OUT");
                assert_eq!(stage.cycles, 1, "an open-ended stage repeats nothing");
                assert_eq!(ordinal, 1, "the retention follows the fast breaths");
            }
        }

        let wim_hof = TECHNIQUES
            .iter()
            .find(|technique| technique.slug == WIM_HOF)
            .expect("the catalogue contains the Wim Hof-style rounds");

        assert!(
            wim_hof.stages.iter().any(|stage| stage.open_ended),
            "the retention lost its open-ended flag"
        );
    }

    /// The strongest safety framing in the app belongs to the one technique that
    /// can make someone faint. Losing it to a copy edit is the regression here.
    #[test]
    fn the_contraindicated_techniques_carry_their_warnings() {
        for slug in [WIM_HOF, "bellows-breath"] {
            let technique = TECHNIQUES
                .iter()
                .find(|technique| technique.slug == slug)
                .unwrap_or_else(|| panic!("the catalogue contains `{slug}`"));

            assert!(
                !technique.safety_note.is_empty(),
                "`{slug}` carries no safety note"
            );
            for phrase in ["water", "driv"] {
                assert!(
                    technique.safety_note.contains(phrase),
                    "`{slug}` no longer warns about `{phrase}`"
                );
            }
        }
    }

    /// The labels are bound as text and only checked when Postgres casts them,
    /// so a typo here is a failed migration rather than a compile error.
    #[test]
    fn goals_and_phase_kinds_are_labels_the_database_knows() {
        for technique in TECHNIQUES {
            assert!(
                ["CALM", "SLEEP", "ENERGY", "RESET", "FOCUS"].contains(&technique.goal),
                "`{}` has goal `{}`, which is not a technique_goal label",
                technique.slug,
                technique.goal
            );

            for stage in technique.stages {
                for phase in stage.phases {
                    assert!(
                        ["INHALE", "HOLD_IN", "EXHALE", "HOLD_OUT"].contains(&phase.kind),
                        "`{}` has phase kind `{}`, which is not a phase_kind label",
                        technique.slug,
                        phase.kind
                    );
                }
            }
        }
    }

    /// Same reasoning as `slugs_are_unique`: the foundations upsert is keyed on
    /// the slug, and the client and M6's assistant both cite topics by it.
    #[test]
    fn foundation_slugs_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for topic in FOUNDATIONS {
            assert!(seen.insert(topic.slug), "duplicate slug `{}`", topic.slug);
            assert!(!topic.question.is_empty(), "`{}` asks nothing", topic.slug);
            assert!(!topic.answer.is_empty(), "`{}` answers nothing", topic.slug);
        }
    }
}
