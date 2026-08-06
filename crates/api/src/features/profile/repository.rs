//! Profile SQL.
//!
//! Reads and writes the answer columns on `users`. The row's existence is
//! `crate::identity`'s business, which is why nothing here inserts.

use sqlx::PgPool;
use uuid::Uuid;

use super::errors::ProfileError;
use super::types::{BirthYearBand, ExperienceLevel, ReminderIntensity};
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
    /// `None` means invisible on every leaderboard. On the way in it is what the
    /// person asked for; on the way out it is what they got, which may carry a
    /// suffix somebody else's identical name forced.
    pub display_name: Option<String>,
    pub birth_year_band: Option<BirthYearBand>,
}

/// The separator between a taken name and the number that disambiguates it.
///
/// A middle dot rather than a digit run-on, so `Tim·2` cannot be misread as a
/// name somebody chose that happens to end in a two.
const DISPLAY_NAME_SUFFIX_SEPARATOR: char = '·';

/// Matches the `CHECK` on `users.display_name`.
const MAX_DISPLAY_NAME_CHARS: usize = 24;

/// How many suffixes to try before giving up.
///
/// Bounded because the loop issues one statement per attempt: a name so popular
/// that fifty variants are taken is a signal to think about naming, not a reason
/// to hold a connection open counting.
const MAX_DISPLAY_NAME_ATTEMPTS: u32 = 50;

/// The Postgres SQLSTATE for a unique violation.
const UNIQUE_VIOLATION: &str = "23505";

/// The index that makes display names unique, case-insensitively.
const DISPLAY_NAME_INDEX: &str = "users_display_name_key";

pub async fn find_profile(pool: &PgPool, user_id: Uuid) -> Result<ProfileRow, ProfileError> {
    let row = sqlx::query_as!(
        ProfileRow,
        r#"SELECT
            goals AS "goals: Vec<TechniqueGoal>",
            experience_level AS "experience_level?: ExperienceLevel",
            reminder_intensity AS "reminder_intensity: ReminderIntensity",
            intent_note,
            display_name,
            birth_year_band AS "birth_year_band?: BirthYearBand"
         FROM users
         WHERE id = $1"#,
        user_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(ProfileError::Missing)?;

    Ok(row)
}

/// Replaces every answer column and returns the display name as stored.
///
/// The name is the one column the caller does not get to decide outright: the
/// unique index can refuse it, and the answer to that is a suffix rather than an
/// error, because a person who typed their own first name has done nothing
/// wrong. Each attempt is a fresh statement, so a name taken between the check
/// and the write is caught by the constraint rather than by a race-prone read.
pub async fn replace_profile(
    pool: &PgPool,
    user_id: Uuid,
    profile: &ProfileRow,
) -> Result<Option<String>, ProfileError> {
    let Some(desired) = profile.display_name.as_deref() else {
        write_profile(pool, user_id, profile, None).await?;
        return Ok(None);
    };

    for attempt in 1..=MAX_DISPLAY_NAME_ATTEMPTS {
        let candidate = suffixed(desired, attempt);

        match write_profile(pool, user_id, profile, Some(&candidate)).await {
            Ok(()) => return Ok(Some(candidate)),
            // Taken. Fall through to the next suffix.
            Err(ProfileError::Database(error)) if is_display_name_collision(&error) => {}
            Err(error) => return Err(error),
        }
    }

    Err(ProfileError::DisplayNameUnavailable)
}

/// One statement rather than a read-modify-write: the update is a wholesale
/// replacement, so a concurrent writer can lose but can never merge two callers'
/// answers into a profile neither of them chose.
async fn write_profile(
    pool: &PgPool,
    user_id: Uuid,
    profile: &ProfileRow,
    display_name: Option<&str>,
) -> Result<(), ProfileError> {
    let affected = sqlx::query!(
        "UPDATE users
            SET goals = $2,
                experience_level = $3,
                reminder_intensity = $4,
                intent_note = $5,
                display_name = $6,
                birth_year_band = $7,
                updated_at = now()
          WHERE id = $1",
        user_id,
        &profile.goals as _,
        profile.experience_level as _,
        profile.reminder_intensity as _,
        profile.intent_note,
        display_name,
        profile.birth_year_band as _
    )
    .execute(pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(ProfileError::Missing);
    }

    Ok(())
}

/// The first attempt is the name itself; later ones append a counter, trimming
/// the base so the result still fits the column.
fn suffixed(base: &str, attempt: u32) -> String {
    if attempt == 1 {
        return base.to_owned();
    }

    let suffix = format!("{DISPLAY_NAME_SUFFIX_SEPARATOR}{attempt}");
    let room = MAX_DISPLAY_NAME_CHARS.saturating_sub(suffix.chars().count());

    base.chars().take(room).collect::<String>() + &suffix
}

/// Narrow on purpose: `users` carries a second unique constraint on
/// `apple_user_id`, and retrying a name would be the wrong answer to that one.
fn is_display_name_collision(error: &sqlx::Error) -> bool {
    let sqlx::Error::Database(error) = error else {
        return false;
    };

    error.code().as_deref() == Some(UNIQUE_VIOLATION)
        && error.constraint() == Some(DISPLAY_NAME_INDEX)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The suffix has to fit inside the column's limit, which means eating into
    /// the name rather than growing past it — an over-long candidate would come
    /// back as a `CHECK` violation the caller cannot act on.
    #[test]
    fn a_suffixed_name_still_fits_the_column() {
        let long = "a".repeat(MAX_DISPLAY_NAME_CHARS);

        assert_eq!(suffixed(&long, 1), long);

        for attempt in 2..=MAX_DISPLAY_NAME_ATTEMPTS {
            let candidate = suffixed(&long, attempt);
            assert!(candidate.chars().count() <= MAX_DISPLAY_NAME_CHARS);
            assert!(candidate.ends_with(&format!("{DISPLAY_NAME_SUFFIX_SEPARATOR}{attempt}")));
        }
    }

    /// Truncation counts Unicode scalars, not bytes: the `CHECK` counts
    /// characters, so a byte-wise trim would leave an emoji name well under the
    /// limit and could split one in half.
    #[test]
    fn truncation_counts_characters_not_bytes() {
        let candidate = suffixed(&"🌊".repeat(MAX_DISPLAY_NAME_CHARS), 2);

        assert_eq!(candidate.chars().count(), MAX_DISPLAY_NAME_CHARS);
        assert_eq!(candidate.matches('🌊').count(), MAX_DISPLAY_NAME_CHARS - 2);
    }
}
