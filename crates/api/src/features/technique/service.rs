//! Business logic — assembles rows into the proto response.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use std::collections::HashMap;

use sqlx::PgPool;

use super::errors::TechniqueError;
use super::repository;
use super::types::{PhaseKind, TechniqueGoal};
use crate::proto::breathe::v1 as pb;

pub async fn list_techniques(pool: &PgPool) -> Result<pb::ListTechniquesResponse, TechniqueError> {
    let techniques = repository::list_techniques(pool).await?;
    let phases = repository::list_all_phases(pool).await?;

    // The repository returns phases already ordered by (technique_id, ordinal),
    // so appending in iteration order preserves cycle order per technique.
    let mut phases_by_technique: HashMap<String, Vec<pb::Phase>> =
        HashMap::with_capacity(techniques.len());
    for phase in phases {
        let duration_ms = phase_duration(phase.duration_ms)?;
        phases_by_technique
            .entry(phase.technique_id)
            .or_default()
            .push(pb::Phase {
                kind: phase_kind_to_proto(phase.kind) as i32,
                duration_ms,
            });
    }

    let techniques = techniques
        .into_iter()
        .map(|row| {
            let phases = phases_by_technique.remove(&row.id).ok_or_else(|| {
                TechniqueError::Inconsistent(format!("technique `{}` has no phases", row.slug))
            })?;

            Ok(pb::Technique {
                id: row.id,
                slug: row.slug,
                name: row.name,
                summary: row.summary,
                goal: goal_to_proto(row.goal) as i32,
                phases,
            })
        })
        .collect::<Result<Vec<_>, TechniqueError>>()?;

    Ok(pb::ListTechniquesResponse { techniques })
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
    }
}

/// The schema's `CHECK (duration_ms > 0)` makes a non-positive value
/// unreachable, so one arriving here is corrupt data — fail loudly rather than
/// rewrite it (`unsigned_abs` would surface `-4000` to a client as `4000`).
fn phase_duration(duration_ms: i32) -> Result<u32, TechniqueError> {
    u32::try_from(duration_ms).map_err(|_| {
        TechniqueError::Inconsistent(format!("phase duration `{duration_ms}` is negative"))
    })
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

    /// The proto `_UNSPECIFIED` zero value must be unreachable from a domain
    /// value — a client that receives it cannot tell a real goal from a bug.
    #[test]
    fn no_domain_goal_maps_to_unspecified() {
        for goal in [
            TechniqueGoal::Calm,
            TechniqueGoal::Sleep,
            TechniqueGoal::Energy,
            TechniqueGoal::Reset,
        ] {
            assert_ne!(goal_to_proto(goal), pb::TechniqueGoal::Unspecified);
        }
    }

    #[test]
    fn a_negative_duration_is_an_error_not_a_rewrite() {
        assert_eq!(phase_duration(4000).expect("positive passes through"), 4000);
        assert!(matches!(
            phase_duration(-4000),
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
}
