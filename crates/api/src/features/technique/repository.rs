//! Technique SQL.

use sqlx::PgPool;

use super::errors::TechniqueError;
use super::types::{PhaseKind, TechniqueGoal};

/// A technique without its phases.
pub struct TechniqueRow {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub summary: String,
    pub goal: TechniqueGoal,
}

/// One phase, carrying the id of the technique it belongs to so the caller can
/// group without a second lookup.
pub struct PhaseRow {
    pub technique_id: String,
    pub kind: PhaseKind,
    pub duration_ms: i32,
}

/// Lists techniques in curated presentation order.
pub async fn list_techniques(pool: &PgPool) -> Result<Vec<TechniqueRow>, TechniqueError> {
    let rows = sqlx::query_as!(
        TechniqueRow,
        r#"SELECT
            id,
            slug,
            name,
            summary,
            goal AS "goal: TechniqueGoal"
         FROM techniques
         ORDER BY sort_order"#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Lists every phase of every technique, grouped by technique and in cycle order.
///
/// One query for the whole catalogue rather than one per technique: the
/// catalogue is small and unpaginated, so the per-technique variant would be a
/// textbook N+1 for no benefit.
pub async fn list_all_phases(pool: &PgPool) -> Result<Vec<PhaseRow>, TechniqueError> {
    let rows = sqlx::query_as!(
        PhaseRow,
        r#"SELECT
            technique_id,
            kind AS "kind: PhaseKind",
            duration_ms
         FROM technique_phases
         ORDER BY technique_id, ordinal"#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
