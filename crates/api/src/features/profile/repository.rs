//! Profile SQL.
//!
//! Reads and writes the answer columns on `users`. The row's existence is
//! `crate::identity`'s business, which is why nothing here inserts.

use sqlx::PgPool;
use uuid::Uuid;

use super::errors::ProfileError;
use super::types::{ExperienceLevel, ReminderIntensity};
use crate::features::technique::types::TechniqueGoal;

/// The answer columns of one `users` row.
pub struct ProfileRow {
    /// In the order the person picked them — a Postgres array preserves it, and
    /// the client displays their own ordering back to them.
    pub goals: Vec<TechniqueGoal>,
    /// `None` until they answer, which is the state every row starts in.
    pub experience_level: Option<ExperienceLevel>,
    pub reminder_intensity: ReminderIntensity,
    pub intent_note: String,
}

pub async fn find_profile(pool: &PgPool, user_id: Uuid) -> Result<ProfileRow, ProfileError> {
    let row = sqlx::query_as!(
        ProfileRow,
        r#"SELECT
            goals AS "goals: Vec<TechniqueGoal>",
            experience_level AS "experience_level?: ExperienceLevel",
            reminder_intensity AS "reminder_intensity: ReminderIntensity",
            intent_note
         FROM users
         WHERE id = $1"#,
        user_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(ProfileError::Missing)?;

    Ok(row)
}

/// Replaces every answer column, and reports whether the row was there.
///
/// One statement rather than a read-modify-write: the update is a wholesale
/// replacement, so a concurrent writer can lose but can never merge two callers'
/// answers into a profile neither of them chose.
pub async fn replace_profile(
    pool: &PgPool,
    user_id: Uuid,
    profile: &ProfileRow,
) -> Result<(), ProfileError> {
    let affected = sqlx::query!(
        "UPDATE users
            SET goals = $2,
                experience_level = $3,
                reminder_intensity = $4,
                intent_note = $5,
                updated_at = now()
          WHERE id = $1",
        user_id,
        &profile.goals as _,
        profile.experience_level as _,
        profile.reminder_intensity as _,
        profile.intent_note
    )
    .execute(pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(ProfileError::Missing);
    }

    Ok(())
}
