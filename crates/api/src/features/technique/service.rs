//! Business logic — assembles rows into the proto response.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use std::collections::HashMap;

use sqlx::PgPool;

use super::errors::TechniqueError;
use super::repository::{self, PhaseRow, StageRow};
use super::types::{PhaseKind, TechniqueGoal};
use crate::proto::breathe::v1 as pb;

pub async fn list_techniques(pool: &PgPool) -> Result<pb::ListTechniquesResponse, TechniqueError> {
    // Three sequential reads rather than a `try_join!` of them: the saving is two
    // loopback round-trips on a call each client makes once at launch, and the
    // cost is three pool connections per request instead of one.
    let techniques = repository::list_techniques(pool).await?;
    let stages = repository::list_all_stages(pool).await?;
    let phases = repository::list_all_phases(pool).await?;

    let mut stages_by_technique = assemble_stages(stages, phases)?;

    let techniques = techniques
        .into_iter()
        .map(|row| {
            let stages = stages_by_technique.remove(&row.id).ok_or_else(|| {
                TechniqueError::Inconsistent(format!("technique `{}` has no stages", row.slug))
            })?;
            let recommended_rounds = positive_count("recommended rounds", row.recommended_rounds)?;

            Ok(pb::Technique {
                id: row.id,
                slug: row.slug,
                name: row.name,
                summary: row.summary,
                goal: goal_to_proto(row.goal) as i32,
                stages,
                recommended_rounds,
                safety_note: row.safety_note,
            })
        })
        .collect::<Result<Vec<_>, TechniqueError>>()?;

    Ok(pb::ListTechniquesResponse { techniques })
}

pub async fn list_foundations(
    pool: &PgPool,
) -> Result<pb::ListFoundationsResponse, TechniqueError> {
    let topics = repository::list_foundation_topics(pool)
        .await?
        .into_iter()
        .map(|row| pb::FoundationTopic {
            slug: row.slug,
            question: row.question,
            answer: row.answer,
        })
        .collect();

    Ok(pb::ListFoundationsResponse { topics })
}

/// Folds the two child tables into one stage list per technique.
///
/// Both arrive already ordered — phases by `(technique_id, stage_ordinal,
/// ordinal)` and stages by `(technique_id, ordinal)` — so appending in iteration
/// order is what preserves play order through the grouping. A stage with no
/// phases is corrupt data rather than an empty stage: the client would sit on a
/// segment it can never advance past.
fn assemble_stages(
    stages: Vec<StageRow>,
    phases: Vec<PhaseRow>,
) -> Result<HashMap<String, Vec<pb::Stage>>, TechniqueError> {
    let mut phases_by_stage: HashMap<(String, i32), Vec<pb::Phase>> = HashMap::new();
    for phase in phases {
        phases_by_stage
            .entry((phase.technique_id, phase.stage_ordinal))
            .or_default()
            .push(pb::Phase {
                kind: phase_kind_to_proto(phase.kind) as i32,
                duration_ms: positive_count("phase duration", phase.duration_ms)?,
                min_duration_ms: positive_count("phase minimum", phase.min_duration_ms)?,
                max_duration_ms: positive_count("phase maximum", phase.max_duration_ms)?,
            });
    }

    let mut stages_by_technique: HashMap<String, Vec<pb::Stage>> = HashMap::new();
    for stage in stages {
        let key = (stage.technique_id, stage.ordinal);
        let phases = phases_by_stage.remove(&key).ok_or_else(|| {
            TechniqueError::Inconsistent(format!(
                "stage {} of technique `{}` has no phases",
                key.1, key.0
            ))
        })?;

        stages_by_technique
            .entry(key.0)
            .or_default()
            .push(pb::Stage {
                phases,
                cycles: positive_count("stage cycles", stage.cycles)?,
                open_ended: stage.open_ended,
            });
    }

    Ok(stages_by_technique)
}

/// Written out rather than derived, so that adding a goal to the database enum
/// without adding it to the proto fails to compile here instead of reaching a
/// client as an unmapped zero.
const fn goal_to_proto(goal: TechniqueGoal) -> pb::TechniqueGoal {
    match goal {
        TechniqueGoal::Calm => pb::TechniqueGoal::Calm,
        TechniqueGoal::Sleep => pb::TechniqueGoal::Sleep,
        TechniqueGoal::Energy => pb::TechniqueGoal::Energy,
        TechniqueGoal::Reset => pb::TechniqueGoal::Reset,
        TechniqueGoal::Focus => pb::TechniqueGoal::Focus,
    }
}

/// Narrows a column the schema already constrains to be positive.
///
/// Every `CHECK (… > 0)` makes a negative value unreachable, so one arriving
/// here is corrupt data — fail loudly rather than rewrite it (`unsigned_abs`
/// would surface `-4000` to a client as `4000`).
fn positive_count(field: &str, value: i32) -> Result<u32, TechniqueError> {
    u32::try_from(value)
        .map_err(|_| TechniqueError::Inconsistent(format!("{field} `{value}` is negative")))
}

const fn phase_kind_to_proto(kind: PhaseKind) -> pb::PhaseKind {
    match kind {
        PhaseKind::Inhale => pb::PhaseKind::Inhale,
        PhaseKind::HoldIn => pb::PhaseKind::HoldIn,
        PhaseKind::Exhale => pb::PhaseKind::Exhale,
        PhaseKind::HoldOut => pb::PhaseKind::HoldOut,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage_row(technique_id: &str, ordinal: i32) -> StageRow {
        StageRow {
            technique_id: technique_id.to_owned(),
            ordinal,
            cycles: 1,
            open_ended: false,
        }
    }

    fn phase_row(technique_id: &str, stage_ordinal: i32, kind: PhaseKind) -> PhaseRow {
        PhaseRow {
            technique_id: technique_id.to_owned(),
            stage_ordinal,
            kind,
            duration_ms: 4000,
            min_duration_ms: 2000,
            max_duration_ms: 8000,
        }
    }

    /// The proto `_UNSPECIFIED` zero value must be unreachable from a domain
    /// value — a client that receives it cannot tell a real goal from a bug.
    #[test]
    fn no_domain_goal_maps_to_unspecified() {
        for goal in [
            TechniqueGoal::Calm,
            TechniqueGoal::Sleep,
            TechniqueGoal::Energy,
            TechniqueGoal::Reset,
            TechniqueGoal::Focus,
        ] {
            assert_ne!(goal_to_proto(goal), pb::TechniqueGoal::Unspecified);
        }
    }

    #[test]
    fn a_negative_count_is_an_error_not_a_rewrite() {
        assert_eq!(
            positive_count("phase duration", 4000).expect("positive passes through"),
            4000
        );
        assert!(matches!(
            positive_count("phase duration", -4000),
            Err(TechniqueError::Inconsistent(_))
        ));
    }

    #[test]
    fn no_domain_phase_kind_maps_to_unspecified() {
        for kind in [
            PhaseKind::Inhale,
            PhaseKind::HoldIn,
            PhaseKind::Exhale,
            PhaseKind::HoldOut,
        ] {
            assert_ne!(phase_kind_to_proto(kind), pb::PhaseKind::Unspecified);
        }
    }

    /// The grouping runs through two `HashMap`s, so neither the stage order nor
    /// the phase order within a stage survives by accident. The rows here are
    /// ordered as the queries return them; what this pins is that the assembly
    /// keeps a multi-stage technique's stages in play order rather than in
    /// whichever order the map happens to iterate.
    #[test]
    fn stages_keep_their_play_order_through_the_grouping() {
        let stages = vec![stage_row("wim-hof", 0), stage_row("wim-hof", 1)];
        let phases = vec![
            phase_row("wim-hof", 0, PhaseKind::Inhale),
            phase_row("wim-hof", 0, PhaseKind::Exhale),
            phase_row("wim-hof", 1, PhaseKind::HoldOut),
        ];

        let assembled = assemble_stages(stages, phases).expect("the fixture is consistent");
        let stages = &assembled["wim-hof"];

        assert_eq!(stages.len(), 2);
        assert_eq!(
            stages[0]
                .phases
                .iter()
                .map(|phase| phase.kind)
                .collect::<Vec<_>>(),
            vec![pb::PhaseKind::Inhale as i32, pb::PhaseKind::Exhale as i32]
        );
        assert_eq!(stages[1].phases.len(), 1);
    }

    /// A stage whose phases went missing is corrupt data, not an empty stage —
    /// the client would sit on a segment it can never advance past.
    #[test]
    fn a_phaseless_stage_is_inconsistent() {
        assert!(matches!(
            assemble_stages(vec![stage_row("box-breathing", 0)], vec![]),
            Err(TechniqueError::Inconsistent(_))
        ));
    }
}
