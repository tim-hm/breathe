//! Business logic — validates a submitted profile and converts both ways across
//! the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use sqlx::PgPool;
use uuid::Uuid;

use super::errors::ProfileError;
use super::repository::{self, ProfileRow};
use super::types::{ExperienceLevel, ReminderIntensity};
use crate::features::technique::service::goal_to_proto;
use crate::features::technique::types::TechniqueGoal;
use crate::proto::breathe::v1 as pb;

/// Matches the `CHECK` on `users.intent_note`. Duplicated here so an over-long
/// note comes back as `INVALID_ARGUMENT` naming the field, rather than as the
/// opaque `internal` a constraint violation would become.
const MAX_INTENT_NOTE_CHARS: usize = 500;

pub async fn get_profile(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<pb::GetProfileResponse, ProfileError> {
    let row = repository::find_profile(pool, user_id).await?;

    Ok(pb::GetProfileResponse {
        profile: Some(to_proto(row)),
    })
}

pub async fn update_profile(
    pool: &PgPool,
    user_id: Uuid,
    submitted: Option<pb::Profile>,
) -> Result<pb::UpdateProfileResponse, ProfileError> {
    let submitted =
        submitted.ok_or_else(|| ProfileError::Invalid("`profile` is required".to_owned()))?;
    let row = from_proto(submitted)?;

    repository::replace_profile(pool, user_id, &row).await?;

    Ok(pb::UpdateProfileResponse {
        profile: Some(to_proto(row)),
    })
}

fn to_proto(row: ProfileRow) -> pb::Profile {
    pb::Profile {
        goals: row
            .goals
            .into_iter()
            .map(|goal| goal_to_proto(goal) as i32)
            .collect(),
        experience_level: row
            .experience_level
            .map_or(pb::ExperienceLevel::Unspecified, experience_level_to_proto)
            as i32,
        reminder_intensity: reminder_intensity_to_proto(row.reminder_intensity) as i32,
        intent_note: row.intent_note,
    }
}

/// Narrows a submitted profile to the values the database accepts.
///
/// Every rejection here is a value the wire format admits and the domain does
/// not — the proto zero values, and anything a newer client might add. Rejecting
/// rather than defaulting is the same rule the client applies coming the other
/// way: a value one side cannot represent is never quietly replaced by a guess
/// the person did not make.
fn from_proto(profile: pb::Profile) -> Result<ProfileRow, ProfileError> {
    let mut goals = Vec::with_capacity(profile.goals.len());
    for raw in profile.goals {
        let goal = goal_from_proto(raw)?;
        // Deduplicated rather than rejected: a client sending a goal twice has
        // sent a set with a redundancy, not a contradiction. Insertion order is
        // kept, so the person sees back the order they picked.
        if !goals.contains(&goal) {
            goals.push(goal);
        }
    }

    let intent_note = profile.intent_note.trim().to_owned();
    if intent_note.chars().count() > MAX_INTENT_NOTE_CHARS {
        return Err(ProfileError::Invalid(format!(
            "`intent_note` is longer than {MAX_INTENT_NOTE_CHARS} characters"
        )));
    }

    Ok(ProfileRow {
        goals,
        experience_level: experience_level_from_proto(profile.experience_level)?,
        reminder_intensity: reminder_intensity_from_proto(profile.reminder_intensity)?,
        intent_note,
    })
}

/// The inbound direction has no counterpart in `technique`, which only ever
/// serves goals: this is the one place a client sends one back.
fn goal_from_proto(raw: i32) -> Result<TechniqueGoal, ProfileError> {
    match pb::TechniqueGoal::try_from(raw) {
        Ok(pb::TechniqueGoal::Calm) => Ok(TechniqueGoal::Calm),
        Ok(pb::TechniqueGoal::Sleep) => Ok(TechniqueGoal::Sleep),
        Ok(pb::TechniqueGoal::Energy) => Ok(TechniqueGoal::Energy),
        Ok(pb::TechniqueGoal::Reset) => Ok(TechniqueGoal::Reset),
        Ok(pb::TechniqueGoal::Focus) => Ok(TechniqueGoal::Focus),
        Ok(pb::TechniqueGoal::Unspecified) | Err(_) => Err(ProfileError::Invalid(format!(
            "`{raw}` is not a goal this server knows"
        ))),
    }
}

const fn experience_level_to_proto(level: ExperienceLevel) -> pb::ExperienceLevel {
    match level {
        ExperienceLevel::New => pb::ExperienceLevel::New,
        ExperienceLevel::Occasional => pb::ExperienceLevel::Occasional,
        ExperienceLevel::Regular => pb::ExperienceLevel::Regular,
    }
}

/// `UNSPECIFIED` is the one proto zero value this feature accepts: nobody has to
/// answer how experienced they are, and "they have not said" is a state the
/// column models as `NULL` rather than as a fourth level.
fn experience_level_from_proto(raw: i32) -> Result<Option<ExperienceLevel>, ProfileError> {
    match pb::ExperienceLevel::try_from(raw) {
        Ok(pb::ExperienceLevel::Unspecified) => Ok(None),
        Ok(pb::ExperienceLevel::New) => Ok(Some(ExperienceLevel::New)),
        Ok(pb::ExperienceLevel::Occasional) => Ok(Some(ExperienceLevel::Occasional)),
        Ok(pb::ExperienceLevel::Regular) => Ok(Some(ExperienceLevel::Regular)),
        Err(_) => Err(ProfileError::Invalid(format!(
            "`{raw}` is not an experience level this server knows"
        ))),
    }
}

const fn reminder_intensity_to_proto(intensity: ReminderIntensity) -> pb::ReminderIntensity {
    match intensity {
        ReminderIntensity::Never => pb::ReminderIntensity::Never,
        ReminderIntensity::Gentle => pb::ReminderIntensity::Gentle,
        ReminderIntensity::Daily => pb::ReminderIntensity::Daily,
    }
}

fn reminder_intensity_from_proto(raw: i32) -> Result<ReminderIntensity, ProfileError> {
    match pb::ReminderIntensity::try_from(raw) {
        Ok(pb::ReminderIntensity::Never) => Ok(ReminderIntensity::Never),
        Ok(pb::ReminderIntensity::Gentle) => Ok(ReminderIntensity::Gentle),
        Ok(pb::ReminderIntensity::Daily) => Ok(ReminderIntensity::Daily),
        Err(_) => Err(ProfileError::Invalid(format!(
            "`{raw}` is not a reminder intensity this server knows"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(reminder_intensity: i32) -> pb::Profile {
        pb::Profile {
            goals: vec![],
            experience_level: pb::ExperienceLevel::Unspecified as i32,
            reminder_intensity,
            intent_note: String::new(),
        }
    }

    /// The product promise, pinned at the boundary it could break at: proto3
    /// cannot distinguish an unset field from zero, so an empty message, a
    /// client that predates the field, and a truncated write must all decode to
    /// silence. Renumbering the enum would flip this to GENTLE and nothing else
    /// in the stack would notice.
    #[test]
    fn an_unset_reminder_intensity_is_never() {
        let decoded = from_proto(profile(0)).expect("an empty profile is valid");

        assert_eq!(decoded.reminder_intensity, ReminderIntensity::Never);
        assert_eq!(pb::ReminderIntensity::Never as i32, 0);
        assert_eq!(
            reminder_intensity_to_proto(ReminderIntensity::default()),
            pb::ReminderIntensity::Never
        );
    }

    /// A goal the server cannot represent must fail the call rather than vanish
    /// from the list — a silently shortened set of goals is a profile the person
    /// did not choose and cannot tell apart from one they did.
    #[test]
    fn an_unrepresentable_goal_fails_the_update() {
        for raw in [pb::TechniqueGoal::Unspecified as i32, 99] {
            let mut submitted = profile(0);
            submitted.goals = vec![pb::TechniqueGoal::Calm as i32, raw];

            assert!(matches!(
                from_proto(submitted),
                Err(ProfileError::Invalid(_))
            ));
        }
    }

    #[test]
    fn repeated_goals_collapse_without_reordering() {
        let mut submitted = profile(0);
        submitted.goals = vec![
            pb::TechniqueGoal::Focus as i32,
            pb::TechniqueGoal::Calm as i32,
            pb::TechniqueGoal::Focus as i32,
        ];

        let decoded = from_proto(submitted).expect("duplicates are not an error");

        assert_eq!(
            decoded.goals,
            vec![TechniqueGoal::Focus, TechniqueGoal::Calm]
        );
    }

    /// The column's `CHECK` counts characters; a byte-length test here would
    /// reject a note of emoji the database would have accepted.
    #[test]
    fn the_note_limit_counts_characters_not_bytes() {
        let mut submitted = profile(0);
        submitted.intent_note = "🌊".repeat(MAX_INTENT_NOTE_CHARS);

        assert_eq!(
            from_proto(submitted)
                .expect("a note at the limit is valid")
                .intent_note
                .chars()
                .count(),
            MAX_INTENT_NOTE_CHARS
        );

        let mut over = profile(0);
        over.intent_note = "a".repeat(MAX_INTENT_NOTE_CHARS + 1);
        assert!(matches!(from_proto(over), Err(ProfileError::Invalid(_))));
    }

    /// Every level the database can hold has to arrive as a real proto case —
    /// the zero value means "they have not answered", which is a different
    /// claim from any of them.
    #[test]
    fn no_stored_experience_level_maps_to_unspecified() {
        for level in [
            ExperienceLevel::New,
            ExperienceLevel::Occasional,
            ExperienceLevel::Regular,
        ] {
            assert_ne!(
                experience_level_to_proto(level),
                pb::ExperienceLevel::Unspecified
            );
        }

        assert_eq!(
            experience_level_from_proto(pb::ExperienceLevel::Unspecified as i32)
                .expect("unspecified is a valid answer"),
            None
        );
    }
}
