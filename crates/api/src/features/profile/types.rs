//! Domain enums, mirroring the Postgres types declared in
//! `0004_users_and_profiles.sql`, and the one shape another feature reads.
//!
//! No enum here carries an "unspecified" variant, for the same reason the
//! technique enums don't: a value that reaches the repository is already one the
//! database accepts. Where the proto's zero value is meaningful — an experience
//! level nobody has answered — it is modelled as `Option`, not as a variant.

use crate::features::technique::types::TechniqueGoal;

/// Mirrors the `experience_level` Postgres enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "experience_level", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ExperienceLevel {
    New,
    Occasional,
    Regular,
}

/// How long a display name may be, in characters.
///
/// One constant for the whole feature: validation rejects an over-long name
/// with it, and the collision suffix trims against it. Two copies could
/// disagree, and the pair that disagreed would produce a suffixed candidate the
/// column `CHECK` in `0005_journey.sql` then refuses — an `internal` error for
/// something the caller did nothing wrong to trigger.
pub const MAX_DISPLAY_NAME_CHARS: usize = 24;

/// Mirrors the `birth_year_band` Postgres enum.
///
/// Every variant is renamed explicitly rather than through `rename_all`: the
/// labels contain digits, and no case convention maps `Born1960s` onto
/// `BORN_1960S` in a way anybody should have to guess at.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "birth_year_band")]
pub enum BirthYearBand {
    #[sqlx(rename = "BORN_BEFORE_1960")]
    BornBefore1960,
    #[sqlx(rename = "BORN_1960S")]
    Born1960s,
    #[sqlx(rename = "BORN_1970S")]
    Born1970s,
    #[sqlx(rename = "BORN_1980S")]
    Born1980s,
    #[sqlx(rename = "BORN_1990S")]
    Born1990s,
    #[sqlx(rename = "BORN_2000S")]
    Born2000s,
    #[sqlx(rename = "BORN_2010_OR_LATER")]
    Born2010OrLater,
}

/// Mirrors the `gender` Postgres enum.
///
/// "Rather not say" is `Option::None` end to end, never a variant; the case
/// for the closed list lives on the contract, in `profile_service.proto`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "gender", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Gender {
    Female,
    Male,
    NonBinary,
}

/// Mirrors the `reminder_intensity` Postgres enum.
///
/// `Never` is the default in every direction — the column default, the proto
/// zero value, and the variant a decode falls back to — so nothing that goes
/// wrong along the way can turn silence into a notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, sqlx::Type)]
#[sqlx(type_name = "reminder_intensity", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReminderIntensity {
    #[default]
    Never,
    Gentle,
    Daily,
}

/// What another feature reads off a profile.
///
/// The answers `assistant` derives its prompt and its rule-based fallback from,
/// and nothing else — no display name, no reminder setting. Narrower than the
/// row on purpose: this is the surface the feature promises to keep, so a
/// column added to `users` for this feature's own use cannot become another
/// feature's dependency by accident.
pub struct ProfileSnapshot {
    /// In the order the person picked them, which is the ranking the fallback
    /// sorts by.
    pub goals: Vec<TechniqueGoal>,

    /// `None` until they answer. Read as "new" by the fallback and as "they
    /// have not been asked" by the prompt, which is why it stays an `Option`
    /// rather than being resolved here.
    pub experience_level: Option<ExperienceLevel>,

    /// What the person typed about what they want, already trimmed and bounded
    /// by `super::service`. Empty where they typed nothing.
    pub intent_note: String,

    /// Which decade they were born in, if they said. The assistant reads it —
    /// with `gender` — to calibrate how it interprets a breath-test score,
    /// which is exactly the coarseness the band was designed to carry.
    pub birth_year_band: Option<BirthYearBand>,

    /// Gender, if they said. `None` is "rather not say" and stays that way in
    /// the prompt: the assistant mentions it only when it is present.
    pub gender: Option<Gender>,
}
