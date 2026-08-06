//! Seeds the technique catalogue.
//!
//! The catalogue is curated reference data, not user content, so it lives in
//! code and is reconciled into the database on every run. Editing a summary here
//! and re-running `mise run migrate` is the supported way to change it.
//!
//! Queries in this module are runtime `sqlx::query`, not the compile-time-checked
//! macros used in `crates/api`. This is the one crate that runs *before* the
//! schema exists, so it cannot depend on a prepared cache that could only have
//! been generated against a database this binary is responsible for creating.

use anyhow::{Context, Result};
use sqlx::PgPool;

/// One technique and its cycle, in play order.
struct TechniqueSeed {
    slug: &'static str,
    name: &'static str,
    summary: &'static str,
    /// Matches a label of the `technique_goal` Postgres enum.
    goal: &'static str,
    /// `(phase_kind label, duration in milliseconds)`.
    phases: &'static [(&'static str, i32)],
}

/// Array order is presentation order — `sort_order` is the index, so reordering
/// this list is the only edit needed to reorder the catalogue.
const TECHNIQUES: &[TechniqueSeed] = &[
    TechniqueSeed {
        slug: "box-breathing",
        name: "Box Breathing",
        summary: "Four equal counts — in, hold, out, hold. The most forgiving place to start, \
                  and the one to reach for before something stressful rather than during it.",
        goal: "CALM",
        phases: &[
            ("INHALE", 4000),
            ("HOLD_IN", 4000),
            ("EXHALE", 4000),
            ("HOLD_OUT", 4000),
        ],
    },
    TechniqueSeed {
        slug: "four-seven-eight",
        name: "4-7-8 Breathing",
        summary: "Inhale for four, hold for seven, exhale for eight. The long exhale is doing the \
                  work; if the hold feels strained, shorten all three and keep the ratio.",
        goal: "SLEEP",
        phases: &[("INHALE", 4000), ("HOLD_IN", 7000), ("EXHALE", 8000)],
    },
    TechniqueSeed {
        slug: "physiological-sigh",
        name: "Physiological Sigh",
        summary: "A full inhale, a second short sip of air on top, then a long slow exhale. \
                  One or two rounds is the whole technique — it works in seconds, not minutes.",
        goal: "RESET",
        // Two consecutive INHALE phases, deliberately. The second sip re-inflates
        // collapsed alveoli, and it is a distinct beat the client must cue
        // separately — merging them into one long inhale loses the technique.
        phases: &[("INHALE", 1500), ("INHALE", 700), ("EXHALE", 5000)],
    },
    TechniqueSeed {
        slug: "bellows-breath",
        name: "Bellows Breath",
        summary: "Rapid, forceful, equal inhales and exhales through the nose. Stop at the first \
                  sign of lightheadedness. Never practise this in water or while driving.",
        goal: "ENERGY",
        phases: &[("INHALE", 1000), ("EXHALE", 1000)],
    },
];

pub async fn run(pool: &PgPool) -> Result<()> {
    let mut tx = pool
        .begin()
        .await
        .context("failed to open seed transaction")?;

    for (index, technique) in TECHNIQUES.iter().enumerate() {
        // `id` is only consumed on first insert; on conflict the existing row
        // keeps its id, so reseeding never invalidates a reference held elsewhere.
        let id: String = sqlx::query_scalar(
            r"INSERT INTO techniques (id, slug, name, summary, goal, sort_order)
               VALUES ($1, $2, $3, $4, $5::technique_goal, $6)
               ON CONFLICT (slug) DO UPDATE SET
                 name = EXCLUDED.name,
                 summary = EXCLUDED.summary,
                 goal = EXCLUDED.goal,
                 sort_order = EXCLUDED.sort_order,
                 updated_at = now()
               RETURNING id",
        )
        .bind(cuid2::create_id())
        .bind(technique.slug)
        .bind(technique.name)
        .bind(technique.summary)
        .bind(technique.goal)
        .bind(i32::try_from(index).context("catalogue is impossibly large")?)
        .fetch_one(&mut *tx)
        .await
        .with_context(|| format!("failed to upsert technique `{}`", technique.slug))?;

        // Replace rather than upsert: the cycle is an ordered list, so a shorter
        // edit would otherwise leave the trailing phases of the previous version
        // behind and lengthen the technique silently.
        sqlx::query("DELETE FROM technique_phases WHERE technique_id = $1")
            .bind(&id)
            .execute(&mut *tx)
            .await
            .with_context(|| format!("failed to clear phases for `{}`", technique.slug))?;

        for (ordinal, (kind, duration_ms)) in technique.phases.iter().enumerate() {
            sqlx::query(
                r"INSERT INTO technique_phases (technique_id, ordinal, kind, duration_ms)
                   VALUES ($1, $2, $3::phase_kind, $4)",
            )
            .bind(&id)
            .bind(i32::try_from(ordinal).context("cycle is impossibly long")?)
            .bind(*kind)
            .bind(duration_ms)
            .execute(&mut *tx)
            .await
            .with_context(|| format!("failed to insert phase {ordinal} of `{}`", technique.slug))?;
        }
    }

    tx.commit()
        .await
        .context("failed to commit seed transaction")?;
    tracing::info!(count = TECHNIQUES.len(), "technique catalogue seeded");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A technique with no phases would leave the client with an empty animation
    /// loop and nothing to advance through.
    #[test]
    fn every_technique_has_at_least_one_phase() {
        for technique in TECHNIQUES {
            assert!(
                !technique.phases.is_empty(),
                "`{}` has no phases",
                technique.slug
            );
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

    /// The `duration_ms > 0` CHECK in `0001_init.sql` would reject these at write
    /// time; catching it here names the offending technique instead.
    #[test]
    fn phase_durations_are_positive() {
        for technique in TECHNIQUES {
            for (kind, duration_ms) in technique.phases {
                assert!(
                    *duration_ms > 0,
                    "`{}` has a non-positive {kind} phase",
                    technique.slug
                );
            }
        }
    }
}
