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
/// `hint` field on `breathe.v1.Phase`, seeded beside the durations; that
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

        return stages.map(\.hints)
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
        guard let hint = hint(for: beat, in: hints) else { return beat.kind.spokenInstruction }
        return "\(beat.kind.spokenInstruction), \(hint.lowercased())"
    }

    /// One stage's hints, with the phase kinds they were written against —
    /// the shape check above compares these, not just counts, so a same-length
    /// rewrite of a technique cannot inherit stale hints.
    private struct StageHints {
        let kinds: [PhaseKind]
        let hints: [String?]
    }

    /// Seeded order: in through the left, out through the right, in through
    /// the right, out through the left (see the catalogue's summary).
    private static let table: [String: [StageHints]] = [
        "alternate-nostril": [
            StageHints(
                kinds: [.inhale, .exhale, .inhale, .exhale],
                hints: ["Left nostril", "Right nostril", "Right nostril", "Left nostril"]
            ),
        ],
    ]
}
