import Foundation

/// The outcome a technique is chosen for.
///
/// Distinct from the generated `Breathe_V1_TechniqueGoal` on purpose: that type
/// carries an `UNSPECIFIED` case the wire format can always produce, and every
/// view that switched over it would need a branch for a value that means
/// "the server and this app disagree". Decoding resolves that once, here.
public enum TechniqueGoal: Sendable, CaseIterable {
    case calm
    case sleep
    case energy
    case reset
}

/// One segment of a breathing cycle.
public enum PhaseKind: Sendable, Hashable {
    case inhale
    case holdIn
    case exhale
    case holdOut
}

public struct Phase: Sendable, Hashable {
    public let kind: PhaseKind
    public let duration: Duration

    public init(kind: PhaseKind, duration: Duration) {
        self.kind = kind
        self.duration = duration
    }
}

/// `Hashable` so a list row can push one as a `NavigationStack` value rather
/// than pushing a pre-built destination view.
public struct Technique: Sendable, Identifiable, Hashable {
    public let id: String
    /// The stable key this app pins artwork and haptic patterns to.
    public let slug: String
    public let name: String
    public let summary: String
    public let goal: TechniqueGoal
    /// The cycle, in play order. Never empty — `TechniqueRepository` rejects a
    /// technique without phases rather than handing a view an empty loop.
    public let phases: [Phase]
    /// The curated default number of cycles for a session. At least one; a
    /// person's own preference overrides it for the session they are starting.
    public let recommendedCycles: Int

    public init(
        id: String,
        slug: String,
        name: String,
        summary: String,
        goal: TechniqueGoal,
        phases: [Phase],
        recommendedCycles: Int
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.summary = summary
        self.goal = goal
        self.phases = phases
        self.recommendedCycles = recommendedCycles
    }

    /// How long one full cycle takes.
    public var cycleDuration: Duration {
        phases.reduce(.zero) { $0 + $1.duration }
    }
}

public extension TechniqueGoal {
    var title: String {
        switch self {
        case .calm: "Calm"
        case .sleep: "Sleep"
        case .energy: "Energy"
        case .reset: "Reset"
        }
    }
}

public extension PhaseKind {
    /// What to do, on screen. Two words, present tense, legible at a glance
    /// through half-closed eyes.
    var instruction: String {
        switch self {
        case .inhale: "Breathe in"
        case .holdIn: "Hold"
        case .exhale: "Breathe out"
        case .holdOut: "Hold"
        }
    }

    /// What VoiceOver announces. Longer than `instruction` because the two holds
    /// read identically aloud, and someone who cannot see the orb has only this
    /// to tell them which one they are in.
    var spokenInstruction: String {
        switch self {
        case .inhale: "Breathe in"
        case .holdIn: "Hold, lungs full"
        case .exhale: "Breathe out"
        case .holdOut: "Hold, lungs empty"
        }
    }
}
