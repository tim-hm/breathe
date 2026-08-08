import Foundation

/// When a discreet session touches the wrist, and how the silences between
/// those touches grow.
///
/// Discreet mode is not the ordinary session made quieter. Cueing every breath
/// for half an hour is unfollowable by somebody who is also listening and
/// talking, and it becomes furniture long before it becomes help — which is the
/// noise-then-ignored failure the whole delivery mode exists to avoid. What a
/// discreet session delivers instead is a handful of short guided bursts, each
/// `cyclesPerBurst` of the technique's own pattern in the haptic vocabulary the
/// full-screen session already teaches, with nothing at all in between. That
/// reframing is what makes the decay decidable: the thing being spaced out is
/// bursts, not breaths.
///
/// **Why the gaps grow.** `gaps` widens by roughly 1.6× — three, five, eight,
/// thirteen minutes — for two independent reasons, either of which would be
/// enough on its own. Physiologically, coherent breathing does most of its work
/// in the first few minutes; after that it is maintenance rather than
/// intervention, so the help belongs at the front. Attentionally, a fixed
/// interval habituates: by minute twenty a cue every five minutes has become
/// furniture and stops registering at all. Growing gaps are what keeps each one
/// salient, which is the mechanism rather than a refinement of it.
///
/// **Why it is open-loop.** The better-in-principle version reads heart rate off
/// the wrist and re-densifies when stress climbs. Its failure modes are the
/// wrong shape — buzzing at somebody who had already settled, or falling quiet
/// exactly when they are spiralling — where a fixed curve fails predictably. The
/// responsive version is worth having once this one has been lived with.
///
/// **Why these are constants.** Whether 3-5-8-13 actually helps is not
/// assertable. A test can prove the bursts fall where they are meant to and that
/// nothing makes a sound; only wearing it through a real meeting can say whether
/// the curve is right. Naming the numbers here is what makes being wrong cost
/// four numbers rather than an architecture.
public enum DiscreetCadence {
    /// The silences between bursts, in play order.
    public static let gaps: [Duration] = [
        .seconds(3 * 60),
        .seconds(5 * 60),
        .seconds(8 * 60),
        .seconds(13 * 60),
    ]

    /// How many cycles of the technique's pattern one burst is worth.
    ///
    /// Six, which for the evenly paced techniques this mode is for — coherent
    /// breathing, extended exhale — is six breaths and about a minute: long
    /// enough to entrain to, short enough to ride out without leaving the
    /// conversation you are sitting in.
    public static let cyclesPerBurst = 6

    /// Where each burst begins, measured from the start of the session.
    ///
    /// One longer than `gaps`, because the first burst opens the session and
    /// every gap is followed by another. Derived rather than written down, so
    /// the curve cannot come to disagree with itself.
    public static let burstStarts: [Duration] = gaps.reduce(into: [.zero]) { starts, gap in
        starts.append((starts.last ?? .zero) + gap)
    }

    /// One burst of `technique`, laid out from t = 0 like any other session.
    ///
    /// The first stage's pattern and nothing else, which is the whole of a
    /// cyclic technique — the two this mode is meant for have no second stage,
    /// and a multi-stage technique's later stages are not what somebody wants
    /// arriving unannounced in a meeting.
    ///
    /// - Parameter technique: the technique being delivered discreetly. One
    ///   with no stages yields an empty burst rather than trapping; the
    ///   catalogue cannot produce one, and a session is not worth a crash.
    public static func burst(of technique: Technique) -> SessionTimeline {
        guard let stage = technique.stages.first else {
            return SessionTimeline(stages: [], rounds: 1)
        }

        return SessionTimeline(
            stages: [Stage(phases: stage.phases, cycles: cyclesPerBurst)],
            rounds: 1
        )
    }

    /// How long a discreet session over `technique` lasts: every gap, plus the
    /// closing burst that outlives the last of them.
    ///
    /// - Parameter technique: the technique being delivered discreetly.
    public static func duration(of technique: Technique) -> Duration {
        gaps.reduce(.zero, +) + burst(of: technique).totalDuration
    }
}
