//! What a person authored, and the limits it has to fit inside.
//!
//! Two kinds of limit live here, and only one of them is a constant. The safe
//! duration of a phase is the catalogue's answer and is read from it
//! ([`PhaseLimits`]); how many stages, cycles and rounds a technique may have is
//! structural — a ceiling on size rather than on physiology — and is stated
//! below.

use crate::features::technique::types::{PhaseKind, TechniqueGoal};

/// Matches the `CHECK` on `user_techniques.name`. Duplicated from the schema so
/// an over-long name comes back as `INVALID_ARGUMENT` naming the field, rather
/// than as the opaque `internal` a constraint violation would become.
pub const MAX_NAME_CHARS: u32 = 60;

/// As many stages as the longest seeded protocol has — the four of a Wim
/// Hof-style round. A ceiling on complexity rather than on safety: nothing
/// composed of closed stages gets dangerous by having another one, but an
/// unbounded stage list is an unbounded write.
pub const MAX_STAGES: u32 = 4;

/// Twice the longest seeded pattern (box breathing's four beats), so a person
/// can compose something the catalogue does not contain without the list
/// becoming a place to store a session's worth of individually timed breaths.
pub const MAX_PHASES_PER_STAGE: u32 = 8;

/// The same ceilings the iOS dials already offer on a catalogue technique
/// (`TechniqueOverrides.cycleRange` and `.roundRange`). Restated here because
/// this is the side that decides, and a client is free to offer less.
pub const MAX_CYCLES: i32 = 99;
pub const MAX_ROUNDS: i32 = 10;

/// How many techniques one person may keep.
///
/// Not a product ceiling anybody asked for — it is the bound on what a caller
/// whose whole credential is a UUID they generated can make this database
/// store. Generous enough that reaching it means somebody is collecting rather
/// than practising.
pub const MAX_TECHNIQUES: u32 = 20;

/// A technique as somebody composed it, after validation.
///
/// Distinct from the proto draft in exactly the way `technique::types`' enums
/// are distinct from the generated ones: every value in here has already been
/// checked against the limits, so the repository writes without a second
/// opinion and the `CHECK`s below it are a backstop rather than the guard.
pub struct AuthoredTechnique {
    pub name: String,
    pub goal: TechniqueGoal,
    pub rounds: i32,
    /// In play order. Never empty.
    pub stages: Vec<AuthoredStage>,
}

pub struct AuthoredStage {
    /// In cycle order. Never empty.
    pub phases: Vec<AuthoredPhase>,
    pub cycles: i32,
}

pub struct AuthoredPhase {
    pub kind: PhaseKind,
    pub duration_ms: i32,
}

/// The safe duration range for each phase kind somebody may author.
///
/// Derived from the seeded catalogue rather than declared — see
/// [`super::repository::phase_limits`] for the query and why open-ended stages
/// are left out of it. Held as a list rather than a map because there are four
/// kinds and the wire wants it ordered anyway.
pub struct PhaseLimits(Vec<PhaseLimit>);

pub struct PhaseLimit {
    pub kind: PhaseKind,
    pub min_duration_ms: i32,
    pub max_duration_ms: i32,
}

impl PhaseLimits {
    pub const fn new(limits: Vec<PhaseLimit>) -> Self {
        Self(limits)
    }

    /// The range a phase of `kind` may be authored within, or `None` for a kind
    /// the catalogue never uses in a closed stage.
    ///
    /// `None` is a refusal rather than a fallback: a kind with no seeded range
    /// has no evidence behind any duration, and inventing one here would be this
    /// server making up the safety limit it exists to enforce.
    pub fn range(&self, kind: PhaseKind) -> Option<&PhaseLimit> {
        self.0.iter().find(|limit| limit.kind == kind)
    }

    pub fn iter(&self) -> impl Iterator<Item = &PhaseLimit> {
        self.0.iter()
    }
}
