//! Domain enums, mirroring the Postgres types declared in `0001_init.sql`.
//!
//! These are distinct from the generated proto enums on purpose. A proto enum is
//! an `i32` with an `_UNSPECIFIED` zero value that the wire format can always
//! produce; these types have no such variant, so a value that reaches the
//! repository is already known to be one of the four the database accepts.

/// Mirrors the `technique_goal` Postgres enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "technique_goal", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TechniqueGoal {
    Calm,
    Sleep,
    Energy,
    Reset,
    Focus,
}

/// Mirrors the `phase_kind` Postgres enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "phase_kind", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PhaseKind {
    Inhale,
    HoldIn,
    Exhale,
    HoldOut,
}
