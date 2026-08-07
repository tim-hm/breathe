import Foundation

/// The outcome a technique is chosen for.
///
/// Distinct from the generated `Breathe_V1_TechniqueGoal` on purpose: that type
/// carries an `UNSPECIFIED` case the wire format can always produce, and every
/// view that switched over it would need a branch for a value that means
/// "the server and this app disagree". Decoding resolves that once, here.
///
/// The raw value exists so a goal can be written down: the answers someone gives
/// at onboarding are stored locally as JSON, and a synthesised case name is not
/// a key that should survive a refactor.
public enum TechniqueGoal: String, Sendable, CaseIterable, Codable {
    case calm
    case sleep
    case energy
    case reset
    case focus
}

/// One segment of a breathing cycle.
///
/// The raw value is a stored key — the catalogue is cached on disk so the app
/// can breathe offline — and a synthesised case name is not a key that should
/// survive a refactor.
public enum PhaseKind: String, Sendable, Hashable, Codable {
    case inhale
    case holdIn
    case exhale
    case holdOut
}

public struct Phase: Sendable, Hashable, Codable {
    public let kind: PhaseKind
    /// The curated default, and what a session plays unless a dial moved it.
    public let duration: Duration
    /// The evidence-based range this phase may be dialled within, inclusive.
    ///
    /// Seeded per phase rather than assumed, so the Advanced dials are rendered
    /// from the catalogue instead of from limits this app would then have to
    /// keep in step with it. A single-point range means no dial at all.
    public let range: ClosedRange<Duration>

    /// Defaults the range to the duration itself — the honest description of a
    /// phase nobody has widened, and what keeps a hand-built `Phase` in a test
    /// or a preview to one line.
    public init(kind: PhaseKind, duration: Duration, range: ClosedRange<Duration>? = nil) {
        self.kind = kind
        self.duration = duration
        self.range = range ?? duration ... duration
    }

    /// Whether there is anything to drag. False for a hold the person ends.
    public var isAdjustable: Bool {
        range.lowerBound < range.upperBound
    }

    /// The same phase at `duration`, clamped into its own range — a dial cannot
    /// take a phase somewhere the catalogue says it should not go.
    public func dialled(to duration: Duration) -> Self {
        Self(kind: kind, duration: range.clamping(duration), range: range)
    }
}

/// A run of cycles sharing one phase pattern.
///
/// The general case a plain cyclic technique degenerates to: box breathing is
/// one stage of eight cycles, while a Wim Hof-style round is three — fast
/// breaths, a retention the person ends, then a recovery hold.
public struct Stage: Sendable, Hashable, Codable {
    /// The pattern, in play order. Never empty — `TechniqueRepository` rejects
    /// an empty stage rather than handing a view a loop with nothing in it.
    public let phases: [Phase]
    public let cycles: Int
    /// Whether the person, rather than the clock, decides when this stage ends.
    ///
    /// True only for a retention hold. The session clock stops for one: its
    /// phase durations describe a typical hold, not a scheduled one, so nothing
    /// downstream may treat them as a length.
    public let openEnded: Bool

    public init(phases: [Phase], cycles: Int, openEnded: Bool = false) {
        self.phases = phases
        self.cycles = cycles
        self.openEnded = openEnded
    }

    /// How long one repetition of the pattern takes.
    public var cycleDuration: Duration {
        phases.totalDuration
    }

    /// How long the whole stage takes — nominal for an open-ended one, which is
    /// as good an estimate as exists before the person decides.
    public var duration: Duration {
        cycleDuration * max(cycles, 1)
    }
}

/// `Hashable` so a list row can push one as a `NavigationStack` value rather
/// than pushing a pre-built destination view. `Codable` because the last
/// fetched catalogue is kept on disk — the app breathes offline from it.
public struct Technique: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    /// The stable key this app pins artwork and haptic patterns to.
    public let slug: String
    public let name: String
    public let summary: String
    public let goal: TechniqueGoal
    /// The session, in play order. Never empty.
    public let stages: [Stage]
    /// The curated default number of times a session repeats the whole stage
    /// list. One for everything cyclic; a person's own preference overrides it
    /// for the session they are starting.
    public let recommendedRounds: Int
    /// The caution this technique carries, or nil where it carries none.
    ///
    /// Separate from `summary` because it has a second audience: the summary is
    /// read while choosing, this while breathing.
    public let safetyNote: String?

    /// The tier this one needs. `.free` for the two the app opens with,
    /// `.plus` for the rest.
    ///
    /// A tier rather than a boolean so a gate is the same comparison everywhere
    /// — and so a future technique behind Coach needs no new field. Defaulted to
    /// `.free` in the initialiser, which mirrors the proto's zero value and
    /// keeps every hand-built `Technique` in a test or a preview to the lines it
    /// already had: a decode gap that locked something must never be the quiet
    /// outcome.
    public let requires: SubscriptionTier

    public init(
        id: String,
        slug: String,
        name: String,
        summary: String,
        goal: TechniqueGoal,
        stages: [Stage],
        recommendedRounds: Int,
        safetyNote: String? = nil,
        requires: SubscriptionTier = .free
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.summary = summary
        self.goal = goal
        self.stages = stages
        self.recommendedRounds = recommendedRounds
        self.safetyNote = safetyNote
        self.requires = requires
    }

    /// Whether `tier` opens this technique.
    ///
    /// On the type rather than at each call site, because "can this person
    /// breathe this" is asked from the list, the detail screen, the home wheel,
    /// and the watch — and four copies of a comparison is four chances to write
    /// `>` where `>=` belongs.
    public func isUnlocked(for tier: SubscriptionTier) -> Bool {
        tier >= requires
    }

    /// Whether any stage waits on the person rather than the clock — which is
    /// what makes this technique's length an estimate rather than a promise.
    public var hasOpenEndedStage: Bool {
        stages.contains(where: \.openEnded)
    }

    /// Whether this is a staged protocol rather than one cycle repeated.
    ///
    /// The distinction the interface turns on: a staged technique is dialled in
    /// rounds and described stage by stage, a cyclic one in cycles.
    public var isStaged: Bool {
        stages.count > 1
    }

    /// How long a session takes at these settings.
    ///
    /// An open-ended stage counts at the typical hold it is seeded with, so this
    /// is an estimate for any technique that has one — the same number
    /// `SessionTimeline` lays out, without laying out every beat to find it.
    public var plannedDuration: Duration {
        stages.reduce(.zero) { $0 + $1.duration } * max(recommendedRounds, 1)
    }
}

extension [Phase] {
    /// How long the sequence takes end to end.
    ///
    /// One definition, so a technique's advertised cycle length and the length
    /// `SessionTimeline` actually lays out cannot drift apart.
    var totalDuration: Duration {
        reduce(.zero) { $0 + $1.duration }
    }
}

public extension TechniqueGoal {
    var title: String {
        switch self {
        case .calm: "Calm"
        case .sleep: "Sleep"
        case .energy: "Energy"
        case .reset: "Reset"
        case .focus: "Focus"
        }
    }

    /// The goal as the person would say it — "I want to calm down" — for
    /// wherever a full sentence fits, like the catalogue's section headers.
    /// First person on purpose: choosing an outcome you want is a more
    /// assertive start than reading a category label.
    var intent: String {
        "I want to \(intentObject)"
    }

    /// The intent without its "I want to" prefix, for the home screen's
    /// wheel, which renders the prefix as a fixed label beside the options.
    /// One word each, so the spun-past neighbours read at a glance.
    var intentObject: String {
        switch self {
        case .calm: "relax"
        case .sleep: "sleep"
        case .energy: "wake"
        case .reset: "reset"
        case .focus: "focus"
        }
    }
}

public extension PhaseKind {
    /// Whether the breath is being held rather than moving.
    ///
    /// The distinction both breath guides key their colour off: a hold is the
    /// one phase where nothing is scaling, so with cues off the colour is all
    /// that marks the change.
    var isHold: Bool {
        switch self {
        case .holdIn, .holdOut: true
        case .inhale, .exhale: false
        }
    }

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
