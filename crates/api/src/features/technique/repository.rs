//! Technique SQL.

use sqlx::PgPool;

use super::errors::TechniqueError;
use super::types::{PhaseKind, TechniqueGoal};

/// A technique without its stages.
pub struct TechniqueRow {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub summary: String,
    pub safety_note: String,
    pub goal: TechniqueGoal,
    pub recommended_rounds: i32,
    /// Whether breathing this one needs a subscription. Carried to the client
    /// and enforced only there — see the field note in the proto.
    pub requires_subscription: bool,
}

/// One stage, carrying the id of the technique it belongs to so the caller can
/// group without a second lookup.
pub struct StageRow {
    pub technique_id: String,
    pub ordinal: i32,
    pub cycles: i32,
    pub open_ended: bool,
}

/// One phase, carrying the stage it belongs to for the same reason.
pub struct PhaseRow {
    pub technique_id: String,
    pub stage_ordinal: i32,
    pub kind: PhaseKind,
    pub duration_ms: i32,
    pub min_duration_ms: i32,
    pub max_duration_ms: i32,
}

pub struct FoundationTopicRow {
    pub slug: String,
    pub question: String,
    pub answer: String,
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
            safety_note,
            goal AS "goal: TechniqueGoal",
            recommended_rounds,
            requires_subscription
         FROM techniques
         ORDER BY sort_order"#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Lists every stage of every technique, grouped by technique and in play order.
///
/// One query for the whole catalogue rather than one per technique, for the same
/// reason as the phases below: the catalogue is small and unpaginated, so the
/// per-technique variant would be a textbook N+1 for no benefit.
pub async fn list_all_stages(pool: &PgPool) -> Result<Vec<StageRow>, TechniqueError> {
    let rows = sqlx::query_as!(
        StageRow,
        r"SELECT technique_id, ordinal, cycles, open_ended
          FROM technique_stages
          ORDER BY technique_id, ordinal"
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Lists every phase of every technique, grouped by stage and in cycle order.
pub async fn list_all_phases(pool: &PgPool) -> Result<Vec<PhaseRow>, TechniqueError> {
    let rows = sqlx::query_as!(
        PhaseRow,
        r#"SELECT
            technique_id,
            stage_ordinal,
            kind AS "kind: PhaseKind",
            duration_ms,
            min_duration_ms,
            max_duration_ms
         FROM technique_phases
         ORDER BY technique_id, stage_ordinal, ordinal"#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Lists the breathing foundations in curated reading order.
pub async fn list_foundation_topics(
    pool: &PgPool,
) -> Result<Vec<FoundationTopicRow>, TechniqueError> {
    let rows = sqlx::query_as!(
        FoundationTopicRow,
        r"SELECT slug, question, answer
          FROM foundation_topics
          ORDER BY sort_order"
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
