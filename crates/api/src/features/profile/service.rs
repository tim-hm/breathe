//! Business logic — validates a submitted profile and converts both ways across
//! the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use sqlx::PgPool;
use uuid::Uuid;

use super::errors::ProfileError;
use super::repository::{self, ProfileRow};
use super::types::{BirthYearBand, ExperienceLevel, MAX_DISPLAY_NAME_CHARS, ReminderIntensity};
use crate::features::technique::service::goal_to_proto;
use crate::features::technique::types::TechniqueGoal;
use crate::proto::breathe::v1 as pb;

/// Matches the `CHECK` on `users.intent_note`. Duplicated here so an over-long
/// note comes back as `INVALID_ARGUMENT` naming the field, rather than as the
/// opaque `internal` a constraint violation would become.
const MAX_INTENT_NOTE_CHARS: usize = 500;

/// The floor the column does not express as its own value; the ceiling lives in
/// `super::types` because the suffixing in `super::repository` trims against it
/// too.
const MIN_DISPLAY_NAME_CHARS: usize = 2;

/// Names nobody may take, matched as a lowercase substring.
///
/// A const in this feature rather than a config knob: it is a product decision
/// about what a leaderboard is allowed to say, and a list somebody can edit
/// without a review is a list that eventually says something the app has to
/// apologise for. Two kinds of entry, and both are impersonation in the end —
/// words that claim to speak for the app, and the handful of slurs and
/// obscenities nobody should have to read next to their own name.
///
/// Deliberately short. A real screening surface is a moderation service with a
/// maintained corpus and an appeals path; this is the floor under V1, not that.
const DENIED_DISPLAY_NAME_FRAGMENTS: &[&str] = &[
    "admin",
    "moderator",
    "official",
    "support",
    "breathe team",
    "staff",
    "fuck",
    "shit",
    "cunt",
    "bitch",
    "rape",
    "nazi",
    "hitler",
];

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
    let mut row = from_proto(submitted)?;

    // The stored name can differ from the requested one — somebody already
    // holds it — and the response is what the client keeps, so the row is
    // corrected before it is converted rather than after.
    row.display_name = repository::replace_profile(pool, user_id, &row).await?;

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
        display_name: row.display_name.unwrap_or_default(),
        birth_year_band: row
            .birth_year_band
            .map_or(pb::BirthYearBand::Unspecified, birth_year_band_to_proto)
            as i32,
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
        display_name: display_name_from_proto(&profile.display_name)?,
        birth_year_band: birth_year_band_from_proto(profile.birth_year_band)?,
    })
}

/// Narrows a submitted display name, or reports that it is not one this app will
/// print.
///
/// Empty is the answer to "I do not want to be on the boards", so it is a
/// `None` rather than a rejection — and clearing a name has to stay as easy as
/// setting one. Everything else is a value somebody typed, and rejecting it with
/// a reason is better than quietly storing a mangled version of it.
///
/// Length counts Unicode scalars, matching the column's `CHECK` and the client's
/// own limit: a byte count would refuse a perfectly short name written in a
/// script that does not fit in one byte per character.
fn display_name_from_proto(submitted: &str) -> Result<Option<String>, ProfileError> {
    let name = submitted.trim();
    if name.is_empty() {
        return Ok(None);
    }

    let length = name.chars().count();
    if !(MIN_DISPLAY_NAME_CHARS..=MAX_DISPLAY_NAME_CHARS).contains(&length) {
        return Err(ProfileError::Invalid(format!(
            "`display_name` must be between {MIN_DISPLAY_NAME_CHARS} and {MAX_DISPLAY_NAME_CHARS} characters"
        )));
    }

    // A name is drawn on one line beside a number. A control character would
    // either break that line or render as nothing, and neither is a name.
    if name.chars().any(char::is_control) {
        return Err(ProfileError::Invalid(
            "`display_name` may not contain control characters".to_owned(),
        ));
    }

    let folded = name.to_lowercase();
    if DENIED_DISPLAY_NAME_FRAGMENTS
        .iter()
        .any(|fragment| folded.contains(fragment))
    {
        return Err(ProfileError::Invalid(
            "`display_name` is not one we can show on a leaderboard".to_owned(),
        ));
    }

    Ok(Some(name.to_owned()))
}

const fn birth_year_band_to_proto(band: BirthYearBand) -> pb::BirthYearBand {
    match band {
        BirthYearBand::BornBefore1960 => pb::BirthYearBand::BornBefore1960,
        BirthYearBand::Born1960s => pb::BirthYearBand::Born1960s,
        BirthYearBand::Born1970s => pb::BirthYearBand::Born1970s,
        BirthYearBand::Born1980s => pb::BirthYearBand::Born1980s,
        BirthYearBand::Born1990s => pb::BirthYearBand::Born1990s,
        BirthYearBand::Born2000s => pb::BirthYearBand::Born2000s,
        BirthYearBand::Born2010OrLater => pb::BirthYearBand::Born2010OrLater,
    }
}

/// `UNSPECIFIED` is accepted here for the same reason it is on the experience
/// level: nobody has to say when they were born, and most will not.
fn birth_year_band_from_proto(raw: i32) -> Result<Option<BirthYearBand>, ProfileError> {
    match pb::BirthYearBand::try_from(raw) {
        Ok(pb::BirthYearBand::Unspecified) => Ok(None),
        Ok(pb::BirthYearBand::BornBefore1960) => Ok(Some(BirthYearBand::BornBefore1960)),
        Ok(pb::BirthYearBand::Born1960s) => Ok(Some(BirthYearBand::Born1960s)),
        Ok(pb::BirthYearBand::Born1970s) => Ok(Some(BirthYearBand::Born1970s)),
        Ok(pb::BirthYearBand::Born1980s) => Ok(Some(BirthYearBand::Born1980s)),
        Ok(pb::BirthYearBand::Born1990s) => Ok(Some(BirthYearBand::Born1990s)),
        Ok(pb::BirthYearBand::Born2000s) => Ok(Some(BirthYearBand::Born2000s)),
        Ok(pb::BirthYearBand::Born2010OrLater) => Ok(Some(BirthYearBand::Born2010OrLater)),
        Err(_) => Err(ProfileError::Invalid(format!(
            "`{raw}` is not a birth year band this server knows"
        ))),
    }
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
            display_name: String::new(),
            birth_year_band: pb::BirthYearBand::Unspecified as i32,
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

    /// Clearing a name has to stay as easy as setting one: an empty field is
    /// somebody asking to leave the boards, not a malformed request. Whitespace
    /// counts as empty, so a name typed and then deleted a character at a time
    /// still lands on `None`.
    #[test]
    fn an_empty_display_name_opts_out_rather_than_failing() {
        for submitted in ["", "   ", "\n"] {
            assert_eq!(
                display_name_from_proto(submitted).expect("empty is a valid answer"),
                None
            );
        }
    }

    /// The column's `CHECK` counts characters, so a byte-length test here would
    /// reject a short name written in a non-Latin script.
    #[test]
    fn the_display_name_limit_counts_characters_not_bytes() {
        let at_limit = "🌊".repeat(MAX_DISPLAY_NAME_CHARS);
        assert_eq!(
            display_name_from_proto(&at_limit).expect("a name at the limit is valid"),
            Some(at_limit)
        );

        for over_or_under in ["a", &"🌊".repeat(MAX_DISPLAY_NAME_CHARS + 1)] {
            assert!(matches!(
                display_name_from_proto(over_or_under),
                Err(ProfileError::Invalid(_))
            ));
        }
    }

    /// The screen is a substring match on the folded name, so neither casing nor
    /// padding a denied word gets it past — which is the only way a denylist is
    /// worth having at all.
    #[test]
    fn a_denied_name_is_refused_however_it_is_dressed_up() {
        for submitted in ["Admin", "the ADMIN", "  breathe team  ", "xXadminXx"] {
            assert!(
                matches!(
                    display_name_from_proto(submitted),
                    Err(ProfileError::Invalid(_))
                ),
                "`{submitted}` should be refused"
            );
        }

        assert!(display_name_from_proto("Tim").is_ok());
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
