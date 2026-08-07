import Foundation

/// Presentation nuance the catalogue does not carry: a hint line per phase,
/// for techniques where the phase kind alone is not enough to follow — which
/// nostril, for now.
///
/// Keyed by slug — the same key `SessionSettings` pins a person's dialled
/// durations to, and the one the catalogue promises to keep stable across
/// reseeds — and shape-checked against the technique it is asked about: a
/// reseeded catalogue that reorders or regrows a technique's phases silently
/// drops the hints rather than pinning "left nostril" to the wrong breath.
///
/// Client-side because the contract has nowhere to put it yet. Its home is a
/// `hint` field on `ond.v1.Phase`, seeded beside the durations; that
/// change retires this table and its shape check together.
public enum PhaseHints {
    /// Hints for `technique`, indexed `[stage][phase]` to match
    /// `SessionTimeline.Beat`, or nil where it has none. An entry can be nil
    /// too — a hold between two hinted breaths needs no reminder.
    public static func hints(for technique: Technique) -> [[String?]]? {
        guard let stages = table[technique.slug],
              stages.count == technique.stages.count,
              zip(stages, technique.stages).allSatisfy({ $0.kinds == $1.phases.map(\.kind) })
        else {
            return nil
        }

        return stages.map { $0.hints.map { $0?.text } }
    }

    /// Which side of the midline each phase is drawn on — `+1` above, `-1`
    /// below — indexed `[stage][phase]` exactly as `hints(for:)` is, and nil
    /// throughout where a technique has no sides to alternate between and draws
    /// one-sided against a baseline.
    ///
    /// Stage-indexed rather than flat, so a caller cannot hand stage zero's
    /// sides to stage two's phases. The flat version needed a guard rejecting
    /// every staged technique to stay safe, which quietly meant a staged
    /// protocol that alternated nostrils would draw one-sided and nothing would
    /// say so.
    ///
    /// Signed **per breath, by the nostril the inhale goes through** — not per
    /// phase. Alternate-nostril breathing changes nostril within a breath (in
    /// left, out right), so signing each phase separately would send the line
    /// across the midline at full lungs and draw a jump where the exercise has
    /// none. Taking the inhale's side for the exhale that empties it keeps every
    /// crossing at empty lungs, which is where the breath actually pauses.
    public static func sides(for technique: Technique) -> [[Double]?]? {
        guard let stages = table[technique.slug], hints(for: technique) != nil else { return nil }

        let sides = zip(stages, technique.stages).map { stage, phases -> [Double]? in
            guard stage.hints.contains(where: { $0 != nil }) else { return nil }

            var sides: [Double] = []
            var current = Side.left

            for (hint, phase) in zip(stage.hints, phases.phases) {
                if phase.kind == .inhale, let hint {
                    current = hint.side
                }
                sides.append(current.rawValue)
            }
            return sides
        }

        return sides.contains(where: { $0 != nil }) ? sides : nil
    }

    /// The hint for `beat` within a table from `hints(for:)` — "Left nostril" —
    /// or nil for an unhinted phase, a technique with no table, and a beat past
    /// the end of one. Total in `hints` as well as in `beat`, because the table
    /// is shape-checked against the technique it was fetched for and nothing
    /// stops a caller pairing it with a different session's beat.
    public static func hint(for beat: SessionTimeline.Beat?, in hints: [[String?]]?) -> String? {
        guard let beat, let hints,
              hints.indices.contains(beat.stage),
              hints[beat.stage].indices.contains(beat.phase)
        else {
            return nil
        }
        return hints[beat.stage][beat.phase]
    }

    /// "Breathe in, left nostril" — the phase as VoiceOver should say it.
    ///
    /// The hint rides along whatever the guidance level: wanting a quieter
    /// screen is not the same as hearing nothing.
    public static func spokenPhase(
        for beat: SessionTimeline.Beat?,
        in hints: [[String?]]?
    ) -> String {
        guard let beat else { return "" }
        return spoken(beat.kind, hint: hint(for: beat, in: hints))
    }

    /// "Breathe in, left nostril" — one phase as it should be said aloud.
    ///
    /// One composition, because the same sentence is spoken twice about the same
    /// exercise: while somebody is choosing it (the figure's description) and
    /// while they are breathing it (the player's announcements). Two spellings
    /// of it would drift with nothing comparing them.
    static func spoken(_ kind: PhaseKind, hint: String?) -> String {
        guard let hint else { return kind.spokenInstruction }
        return "\(kind.spokenInstruction), \(hint.lowercased())"
    }

    /// One stage's hints, with the phase kinds they were written against —
    /// the shape check above compares these, not just counts, so a same-length
    /// rewrite of a technique cannot inherit stale hints.
    private struct StageHints {
        let kinds: [PhaseKind]
        let hints: [Hint?]
    }

    /// One phase's hint: the words for it, and the side of the body it happens
    /// on.
    ///
    /// The side is a value rather than something read back out of the words.
    /// It decides the *shape* of the drawing — which half of the midline a
    /// breath is drawn on — and parsing that out of "Left nostril" means
    /// rewording the sentence, or translating it, silently redraws the figure
    /// with nothing failing.
    struct Hint {
        let text: String
        let side: Side

        init(_ text: String, _ side: Side) {
            self.text = text
            self.side = side
        }
    }

    /// Which side of the midline a breath is drawn on. Left is positive because
    /// the catalogue's cycle starts there, so the figure opens by climbing —
    /// the same up-is-filling reading every other drawing has.
    public enum Side: Double, Sendable {
        case left = 1
        case right = -1
    }

    /// Seeded order: in through the left, out through the right, in through
    /// the right, out through the left (see the catalogue's summary).
    private static let table: [String: [StageHints]] = [
        "alternate-nostril": [
            StageHints(
                kinds: [.inhale, .exhale, .inhale, .exhale],
                hints: [
                    Hint("Left nostril", .left),
                    Hint("Right nostril", .right),
                    Hint("Right nostril", .right),
                    Hint("Left nostril", .left),
                ]
            ),
        ],
    ]
}
