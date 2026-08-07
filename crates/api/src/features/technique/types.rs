//! Domain enums, mirroring the Postgres types declared in `0001_init.sql`, and
//! the one shape another feature reads.
//!
//! The enums are distinct from the generated proto enums on purpose. A proto
//! enum is an `i32` with an `_UNSPECIFIED` zero value that the wire format can
//! always produce; these types have no such variant, so a value that reaches the
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

/// One technique as another feature reads it.
///
/// The catalogue's description of a technique without the stages that make it
/// playable: `assistant` names techniques and explains why they work, and how a
/// session is played is the client's business. Returned by
/// [`super::service::catalogue`] so `TechniqueRow` — and the sort order,
/// subscription flag and surrogate id on it — stays inside this feature.
pub struct Technique {
    /// The stable name a client navigates by, and the only string the assistant
    /// is ever allowed to emit as a technique.
    pub slug: String,

    pub name: String,

    /// The curated sentence carrying the mechanism, which is what the
    /// rule-based explanation is built from.
    pub summary: String,

    /// The caution it carries, empty where it carries none.
    pub safety_note: String,

    pub goal: TechniqueGoal,
}

/// The technique a slug names, or `None` for one the catalogue does not hold.
///
/// The one definition of "resolves in the catalogue", shared by everything in
/// `assistant` that has to decide whether a slug is real — the reply parser,
/// the explanation lookup, the prompt's echo guard, and the fallback's goal
/// attribution. That decision is load-bearing for safety (an unresolvable slug
/// is client free text and must never reach a client or a prompt), so any
/// change to how a slug matches happens here or nowhere.
pub fn resolve<'a>(catalogue: &'a [Technique], slug: &str) -> Option<&'a Technique> {
    catalogue.iter().find(|technique| technique.slug == slug)
}
