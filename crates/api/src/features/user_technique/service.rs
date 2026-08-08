//! Business logic — checks a draft against the seeded ranges, and assembles
//! stored rows into the same `Technique` message the catalogue serves.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use std::collections::HashMap;

use sqlx::PgPool;
use uuid::Uuid;

use super::errors::UserTechniqueError;
use super::repository::{self, PhaseRow, StageRow};
use super::types::{
    AuthoredPhase, AuthoredStage, AuthoredTechnique, MAX_CYCLES, MAX_NAME_CHARS,
    MAX_PHASES_PER_STAGE, MAX_ROUNDS, MAX_STAGES, MAX_TECHNIQUES, PhaseLimits,
};
use crate::features::technique::service::{
    goal_from_proto, goal_to_proto, phase_kind_from_proto, phase_kind_to_proto,
};
use crate::identity::UserId;
use crate::proto::ond::v1 as pb;

/// This person's techniques, and the limits a composer has to work inside.
pub async fn list(
    pool: &PgPool,
    user_id: UserId,
) -> Result<pb::ListUserTechniquesResponse, UserTechniqueError> {
    let limits = repository::phase_limits(pool).await?;
    let techniques = repository::list_techniques(pool, user_id).await?;
    let stages = repository::list_stages(pool, user_id).await?;
    let phases = repository::list_phases(pool, user_id).await?;

    let mut stages_by_technique = assemble_stages(stages, phases, &limits)?;

    let techniques = techniques
        .into_iter()
        .map(|row| {
            let stages = stages_by_technique.remove(&row.id).ok_or_else(|| {
                UserTechniqueError::Inconsistent(format!("technique `{}` has no stages", row.id))
            })?;

            Ok(technique_to_proto(
                row.id, &row.name, row.goal, row.rounds, stages,
            ))
        })
        .collect::<Result<Vec<_>, UserTechniqueError>>()?;

    Ok(pb::ListUserTechniquesResponse {
        techniques,
        limits: Some(limits_to_proto(&limits)),
    })
}

/// Stores a draft and returns it as the catalogue would describe it.
pub async fn create(
    pool: &PgPool,
    user_id: UserId,
    draft: Option<pb::TechniqueDraft>,
) -> Result<pb::CreateUserTechniqueResponse, UserTechniqueError> {
    let limits = repository::phase_limits(pool).await?;
    let authored = validate(draft, &limits)?;

    // Counted before the insert rather than enforced by a constraint: "you have
    // twenty already" is a sentence a person can act on, where a unique-violation
    // turned into `internal` is one nobody can.
    let held = repository::count(pool, user_id).await?;
    if held >= i64::from(MAX_TECHNIQUES) {
        return Err(UserTechniqueError::TooMany(format!(
            "you can keep {MAX_TECHNIQUES} of your own exercises — delete one to make room"
        )));
    }

    let id = repository::insert(pool, user_id, &authored).await?;

    Ok(pb::CreateUserTechniqueResponse {
        technique: Some(authored_to_proto(id, &authored, &limits)),
    })
}

/// Replaces a technique this person owns.
///
/// Re-validated against the limits as they are now, not as they were when it was
/// first stored: an edit is a new claim about what is safe to breathe, and it is
/// checked as one.
pub async fn update(
    pool: &PgPool,
    user_id: UserId,
    id: &str,
    draft: Option<pb::TechniqueDraft>,
) -> Result<pb::UpdateUserTechniqueResponse, UserTechniqueError> {
    let id = parse_id(id)?;
    let limits = repository::phase_limits(pool).await?;
    let authored = validate(draft, &limits)?;

    repository::replace(pool, user_id, id, &authored).await?;

    Ok(pb::UpdateUserTechniqueResponse {
        technique: Some(authored_to_proto(id, &authored, &limits)),
    })
}

/// Deletes a technique this person owns, or one they never had.
pub async fn delete(
    pool: &PgPool,
    user_id: UserId,
    id: &str,
) -> Result<pb::DeleteUserTechniqueResponse, UserTechniqueError> {
    let id = parse_id(id)?;
    repository::delete(pool, user_id, id).await?;

    Ok(pb::DeleteUserTechniqueResponse {})
}

/// The stable key a technique somebody built is known by everywhere a catalogue
/// technique is known by its slug — `sessions.technique_slug` above all.
///
/// Prefixed rather than bare, so a slug that resolves to nothing in the
/// catalogue is legible as a personal technique rather than as a corrupted
/// curated one, in a history row or a log line. Nothing parses the prefix back
/// out: the id is the identity, and this is the name it travels under.
fn slug_for(id: Uuid) -> String {
    format!("own-{id}")
}

fn parse_id(id: &str) -> Result<Uuid, UserTechniqueError> {
    Uuid::parse_str(id)
        .map_err(|_| UserTechniqueError::Invalid(format!("`{id}` is not a technique id")))
}

/// Narrows a draft to something the domain accepts, or says which part of it it
/// will not.
///
/// The enforcement clause of the whole feature. Every duration is checked
/// against the range the *catalogue* seeds for its phase kind, so a client that
/// renders a wider dial than it should — or one that skips the dial entirely and
/// posts a number — gets the same answer. The counts below it are structural
/// rather than physiological; both live here because a client is free to offer
/// less than this and must not be trusted to offer no more.
fn validate(
    draft: Option<pb::TechniqueDraft>,
    limits: &PhaseLimits,
) -> Result<AuthoredTechnique, UserTechniqueError> {
    let draft =
        draft.ok_or_else(|| UserTechniqueError::Invalid("`draft` is required".to_owned()))?;

    let name = draft.name.trim().to_owned();
    if name.is_empty() || width(name.chars().count()) > MAX_NAME_CHARS {
        return Err(UserTechniqueError::Invalid(format!(
            "`name` must be between 1 and {MAX_NAME_CHARS} characters"
        )));
    }

    let goal = goal_from_proto(draft.goal).ok_or_else(|| {
        UserTechniqueError::Invalid(format!("`{}` is not a goal this server knows", draft.goal))
    })?;

    let rounds = bounded("rounds", draft.rounds, MAX_ROUNDS)?;

    if draft.stages.is_empty() || width(draft.stages.len()) > MAX_STAGES {
        return Err(UserTechniqueError::Invalid(format!(
            "an exercise has between 1 and {MAX_STAGES} stages"
        )));
    }

    let stages = draft
        .stages
        .into_iter()
        .enumerate()
        .map(|(index, stage)| validate_stage(index + 1, stage, limits))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(AuthoredTechnique {
        name,
        goal,
        rounds,
        stages,
    })
}

/// `position` is 1-based, because it appears in a message somebody reads beside
/// the stage they are editing.
fn validate_stage(
    position: usize,
    stage: pb::DraftStage,
    limits: &PhaseLimits,
) -> Result<AuthoredStage, UserTechniqueError> {
    let cycles = bounded("cycles", stage.cycles, MAX_CYCLES)?;

    if stage.phases.is_empty() || width(stage.phases.len()) > MAX_PHASES_PER_STAGE {
        return Err(UserTechniqueError::Invalid(format!(
            "stage {position} must have between 1 and {MAX_PHASES_PER_STAGE} phases"
        )));
    }

    let phases = stage
        .phases
        .into_iter()
        .enumerate()
        .map(|(index, phase)| validate_phase(position, index + 1, phase, limits))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(AuthoredStage { phases, cycles })
}

fn validate_phase(
    stage: usize,
    position: usize,
    phase: pb::DraftPhase,
    limits: &PhaseLimits,
) -> Result<AuthoredPhase, UserTechniqueError> {
    let kind = phase_kind_from_proto(phase.kind).ok_or_else(|| {
        UserTechniqueError::Invalid(format!(
            "phase {position} of stage {stage} is not a kind this server knows"
        ))
    })?;

    let limit = limits.range(kind).ok_or_else(|| {
        UserTechniqueError::Invalid(format!(
            "phase {position} of stage {stage} is of a kind with no safe range to breathe it in"
        ))
    })?;

    // Converted before comparing so that a duration past `i32::MAX` is refused
    // as a duration rather than wrapping into the range on its way to the column.
    let duration_ms = i32::try_from(phase.duration_ms).unwrap_or(i32::MAX);
    if duration_ms < limit.min_duration_ms || duration_ms > limit.max_duration_ms {
        return Err(UserTechniqueError::Invalid(format!(
            "phase {position} of stage {stage} must be between {}ms and {}ms",
            limit.min_duration_ms, limit.max_duration_ms
        )));
    }

    Ok(AuthoredPhase { kind, duration_ms })
}

/// How many things there are, in the width the limits are stated in.
///
/// Saturating rather than wrapping: a list of more than four billion phases is
/// over every ceiling here whatever the exact number, and wrapping would put it
/// under one.
fn width(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}

/// Narrows one of the wire's unsigned counts to the closed range `1..=max`.
fn bounded(field: &str, value: u32, max: i32) -> Result<i32, UserTechniqueError> {
    let value = i32::try_from(value).unwrap_or(i32::MAX);
    if value < 1 || value > max {
        return Err(UserTechniqueError::Invalid(format!(
            "`{field}` must be between 1 and {max}"
        )));
    }

    Ok(value)
}

/// The technique a write just stored, without reading it back.
///
/// The validated draft is already exactly what went into the tables, so a
/// round-trip would spend three queries confirming what this process just wrote.
fn authored_to_proto(
    id: Uuid,
    authored: &AuthoredTechnique,
    limits: &PhaseLimits,
) -> pb::Technique {
    let stages = authored
        .stages
        .iter()
        .map(|stage| pb::Stage {
            phases: stage
                .phases
                .iter()
                .map(|phase| phase_to_proto(phase.kind, phase.duration_ms, limits))
                .collect(),
            cycles: stage.cycles.unsigned_abs(),
            open_ended: false,
        })
        .collect();

    technique_to_proto(id, &authored.name, authored.goal, authored.rounds, stages)
}

/// The one place a stored technique becomes the message the catalogue also
/// speaks, which is what lets a client play both through one path.
///
/// Three fields are empty by construction rather than by omission. There is no
/// `summary`, because a sentence explaining an exercise to the person who wrote
/// it is nobody's idea of useful; no `safety_note`, because the ranges it would
/// caution about are the ones this feature refuses to leave; and
/// `requires_subscription` is false, because what is being served back is their
/// own work.
fn technique_to_proto(
    id: Uuid,
    name: &str,
    goal: crate::features::technique::types::TechniqueGoal,
    rounds: i32,
    stages: Vec<pb::Stage>,
) -> pb::Technique {
    pb::Technique {
        id: id.to_string(),
        slug: slug_for(id),
        name: name.to_owned(),
        summary: String::new(),
        goal: goal_to_proto(goal) as i32,
        stages,
        recommended_rounds: rounds.unsigned_abs(),
        safety_note: String::new(),
        requires_subscription: false,
    }
}

/// Stamps the seeded range onto a stored phase.
///
/// Widened to contain the stored duration where the two disagree. They can only
/// disagree by the catalogue's ranges having narrowed since the technique was
/// authored, and the alternative readings are both worse: refusing the phase
/// costs the person their whole list over a seed edit, and clamping it changes
/// what their exercise does without telling them. Widening here keeps it
/// playing as authored, and the next edit is validated against the current
/// range like any other.
fn phase_to_proto(
    kind: crate::features::technique::types::PhaseKind,
    duration_ms: i32,
    limits: &PhaseLimits,
) -> pb::Phase {
    let (min, max) = limits
        .range(kind)
        .map_or((duration_ms, duration_ms), |limit| {
            (limit.min_duration_ms, limit.max_duration_ms)
        });

    pb::Phase {
        kind: phase_kind_to_proto(kind) as i32,
        duration_ms: duration_ms.unsigned_abs(),
        min_duration_ms: min.min(duration_ms).unsigned_abs(),
        max_duration_ms: max.max(duration_ms).unsigned_abs(),
    }
}

fn limits_to_proto(limits: &PhaseLimits) -> pb::AuthoringLimits {
    pb::AuthoringLimits {
        phases: limits
            .iter()
            .map(|limit| pb::PhaseLimit {
                kind: phase_kind_to_proto(limit.kind) as i32,
                min_duration_ms: limit.min_duration_ms.unsigned_abs(),
                max_duration_ms: limit.max_duration_ms.unsigned_abs(),
            })
            .collect(),
        max_name_chars: MAX_NAME_CHARS,
        max_stages: MAX_STAGES,
        max_phases_per_stage: MAX_PHASES_PER_STAGE,
        max_cycles: MAX_CYCLES.unsigned_abs(),
        max_rounds: MAX_ROUNDS.unsigned_abs(),
        max_techniques: MAX_TECHNIQUES,
    }
}

/// Folds the two child tables into one stage list per technique.
///
/// Both arrive ordered by `(technique_id, ordinal)`, so appending in iteration
/// order is what preserves play order through the grouping. Deliberately not
/// shared with the catalogue's own assembly, close as the two look: that one
/// keys on a text id and carries `open_ended` and a per-row range this feature
/// has neither of, and unifying them would mean one function taking three
/// arguments to say which half of itself to run.
fn assemble_stages(
    stages: Vec<StageRow>,
    phases: Vec<PhaseRow>,
    limits: &PhaseLimits,
) -> Result<HashMap<Uuid, Vec<pb::Stage>>, UserTechniqueError> {
    let mut phases_by_stage: HashMap<(Uuid, i32), Vec<pb::Phase>> = HashMap::new();
    for phase in phases {
        phases_by_stage
            .entry((phase.technique_id, phase.stage_ordinal))
            .or_default()
            .push(phase_to_proto(phase.kind, phase.duration_ms, limits));
    }

    let mut stages_by_technique: HashMap<Uuid, Vec<pb::Stage>> = HashMap::new();
    for stage in stages {
        let key = (stage.technique_id, stage.ordinal);
        let phases = phases_by_stage.remove(&key).ok_or_else(|| {
            UserTechniqueError::Inconsistent(format!(
                "stage {} of technique `{}` has no phases",
                key.1, key.0
            ))
        })?;

        stages_by_technique
            .entry(key.0)
            .or_default()
            .push(pb::Stage {
                phases,
                cycles: stage.cycles.unsigned_abs(),
                open_ended: false,
            });
    }

    Ok(stages_by_technique)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::features::technique::types::PhaseKind;
    use crate::features::user_technique::types::PhaseLimit;

    /// A stand-in for what the seed derives to, wide enough that a test can put
    /// a value clearly inside or clearly outside it.
    fn limits() -> PhaseLimits {
        PhaseLimits::new(vec![
            PhaseLimit {
                kind: PhaseKind::Inhale,
                min_duration_ms: 500,
                max_duration_ms: 10_000,
            },
            PhaseLimit {
                kind: PhaseKind::Exhale,
                min_duration_ms: 700,
                max_duration_ms: 12_000,
            },
        ])
    }

    fn phase(kind: pb::PhaseKind, duration_ms: u32) -> pb::DraftPhase {
        pb::DraftPhase {
            kind: kind as i32,
            duration_ms,
        }
    }

    fn draft(phases: Vec<pb::DraftPhase>) -> pb::TechniqueDraft {
        pb::TechniqueDraft {
            name: "Mine".to_owned(),
            goal: pb::TechniqueGoal::Calm as i32,
            stages: vec![pb::DraftStage { phases, cycles: 8 }],
            rounds: 1,
        }
    }

    #[test]
    fn a_draft_inside_the_seeded_ranges_is_accepted() {
        let authored = validate(
            Some(draft(vec![
                phase(pb::PhaseKind::Inhale, 4000),
                phase(pb::PhaseKind::Exhale, 6000),
            ])),
            &limits(),
        )
        .expect("4s in and 6s out sit inside the seeded ranges");

        assert_eq!(authored.stages.len(), 1);
        assert_eq!(authored.stages[0].cycles, 8);
        assert_eq!(
            authored.stages[0]
                .phases
                .iter()
                .map(|phase| (phase.kind, phase.duration_ms))
                .collect::<Vec<_>>(),
            vec![(PhaseKind::Inhale, 4000), (PhaseKind::Exhale, 6000)]
        );
    }

    /// The clause the whole feature exists to hold. A client is free to render
    /// whatever dial it likes; what it cannot do is store a breath the seeded
    /// evidence does not support.
    #[test]
    fn a_phase_outside_its_seeded_range_is_refused_at_either_end() {
        for duration in [400, 10_001] {
            assert!(
                matches!(
                    validate(
                        Some(draft(vec![phase(pb::PhaseKind::Inhale, duration)])),
                        &limits()
                    ),
                    Err(UserTechniqueError::Invalid(_))
                ),
                "{duration}ms is outside the seeded inhale range and must be refused"
            );
        }
    }

    /// A kind the catalogue never uses in a closed stage has no evidence behind
    /// any duration, so it is refused rather than given an invented range —
    /// which is the difference between enforcing a limit and inventing one.
    #[test]
    fn a_phase_kind_with_no_seeded_range_is_refused() {
        assert!(matches!(
            validate(
                Some(draft(vec![phase(pb::PhaseKind::HoldOut, 4000)])),
                &limits()
            ),
            Err(UserTechniqueError::Invalid(_))
        ));
    }

    /// `duration_ms` is unsigned on the wire and signed in the column, so the
    /// conversion is the one place a huge value could wrap into the accepted
    /// range instead of being refused.
    #[test]
    fn an_unrepresentable_duration_is_refused_rather_than_wrapped() {
        assert!(matches!(
            validate(
                Some(draft(vec![phase(pb::PhaseKind::Inhale, u32::MAX)])),
                &limits()
            ),
            Err(UserTechniqueError::Invalid(_))
        ));
    }

    #[test]
    fn the_structural_counts_are_bounded_at_both_ends() {
        let mut no_phases = draft(vec![]);
        no_phases.stages[0].cycles = 8;
        assert!(matches!(
            validate(Some(no_phases), &limits()),
            Err(UserTechniqueError::Invalid(_))
        ));

        let mut no_cycles = draft(vec![phase(pb::PhaseKind::Inhale, 4000)]);
        no_cycles.stages[0].cycles = 0;
        assert!(matches!(
            validate(Some(no_cycles), &limits()),
            Err(UserTechniqueError::Invalid(_))
        ));

        let mut too_many_rounds = draft(vec![phase(pb::PhaseKind::Inhale, 4000)]);
        too_many_rounds.rounds = MAX_ROUNDS.unsigned_abs() + 1;
        assert!(matches!(
            validate(Some(too_many_rounds), &limits()),
            Err(UserTechniqueError::Invalid(_))
        ));

        let mut too_many_stages = draft(vec![phase(pb::PhaseKind::Inhale, 4000)]);
        too_many_stages.stages =
            std::iter::repeat_n(too_many_stages.stages[0].clone(), MAX_STAGES as usize + 1)
                .collect();
        assert!(matches!(
            validate(Some(too_many_stages), &limits()),
            Err(UserTechniqueError::Invalid(_))
        ));
    }

    #[test]
    fn a_nameless_draft_is_refused() {
        let mut nameless = draft(vec![phase(pb::PhaseKind::Inhale, 4000)]);
        nameless.name = "   ".to_owned();

        assert!(matches!(
            validate(Some(nameless), &limits()),
            Err(UserTechniqueError::Invalid(_))
        ));
    }

    /// The client rejects a phase whose duration sits outside its own range, so
    /// a seed that narrowed under a stored technique would cost somebody their
    /// whole list. The range widens to contain what they authored instead.
    #[test]
    fn a_stored_phase_narrower_than_its_range_still_serves() {
        let phase = phase_to_proto(PhaseKind::Inhale, 12_000, &limits());

        assert_eq!(phase.duration_ms, 12_000);
        assert!(phase.min_duration_ms <= phase.duration_ms);
        assert!(phase.duration_ms <= phase.max_duration_ms);
    }

    /// A slug that resolves to nothing in the catalogue reaches the journey's
    /// history and the assistant's prompt, and both have to be able to tell a
    /// personal exercise from a corrupted curated one.
    #[test]
    fn a_personal_slug_is_recognisable_and_fits_the_session_column() {
        let slug = slug_for(Uuid::nil());

        assert!(slug.starts_with("own-"));
        assert!(slug.chars().count() <= 64);
    }
}
