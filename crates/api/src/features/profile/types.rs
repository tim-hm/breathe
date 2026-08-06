//! Domain enums, mirroring the Postgres types declared in
//! `0004_users_and_profiles.sql`.
//!
//! Neither carries an "unspecified" variant, for the same reason the technique
//! enums don't: a value that reaches the repository is already one the database
//! accepts. Where the proto's zero value is meaningful — an experience level
//! nobody has answered — it is modelled as `Option`, not as a variant.

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
