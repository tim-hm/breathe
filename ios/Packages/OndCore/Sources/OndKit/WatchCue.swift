/// The wrist's whole haptic vocabulary: four taps you can tell apart with your
/// eyes shut.
///
/// watchOS has no CoreHaptics, so a phase cannot be *shaped* the way the phone
/// shapes it — there is only a discrete tap at each boundary. What survives that
/// reduction is a decision rather than an API detail: an inhale and an exhale
/// must stay unmistakably different, and the two holds may share a tap because
/// which hold you are in is never in doubt when you are in it.
///
/// The decision lives here, in the shared module, so it can be pinned by a host
/// test; `WKHapticType` is named only in the watch target, which is the half
/// that cannot be tested without a wrist.
public enum WatchCue: Sendable, Equatable {
    /// The lungs filling.
    case rise
    /// The lungs emptying.
    case fall
    /// A boundary with no direction to it — either hold.
    case mark
    /// The session reaching its end, as opposed to being ended.
    case complete
}

public extension WatchCue {
    /// The cue a phase boundary earns.
    ///
    /// Never `.complete`: that one marks the end of the plan, not the start of a
    /// phase, and nothing you are about to breathe should feel like finishing.
    init(_ kind: PhaseKind) {
        self = switch kind {
        case .inhale: .rise
        case .exhale: .fall
        case .holdIn, .holdOut: .mark
        }
    }
}
