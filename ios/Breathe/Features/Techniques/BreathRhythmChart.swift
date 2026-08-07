import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The exercise's rhythm as a line — lung fullness across one round, drawn from
/// the same dialled values the session will play. Because it reads the dialled
/// exercise, it redraws live as the Advanced dials move, which is half the
/// point: the exhale visibly lengthens while the person drags it.
///
/// The list row draws the same curve at row size through `BreathRhythmMark`.
/// Both stand on `RhythmGeometry` and `RhythmInk`, so an exercise is the same
/// shape in the same colours wherever it appears; what this one adds is the
/// stage dividers, the repeat counts, the nostril hints, and the key.
struct BreathRhythmChart: View {
    /// The dialled exercise, not the curated one — the chart is a preview of
    /// the session the Begin button starts.
    let technique: Technique

    private static let lineWidth: CGFloat = 2

    var body: some View {
        let rhythm = BreathRhythm(technique: technique)
        let accent = technique.goal.accent
        let hints = PhaseHints.hints(for: technique)

        VStack(spacing: Theme.Spacing.tight) {
            GeometryReader { geometry in
                let size = geometry.size

                RhythmGeometry.area(rhythm, in: size, inset: Self.lineWidth)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.2), accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                ForEach(RhythmInk.allCases, id: \.self) { ink in
                    strokes(of: rhythm, ink: ink, accent: accent, in: size)
                }

                ForEach(Array(rhythm.bands.dropFirst().enumerated()), id: \.offset) { _, band in
                    Path { path in
                        path.move(to: CGPoint(x: band.start * size.width, y: 0))
                        path.addLine(to: CGPoint(x: band.start * size.width, y: size.height))
                    }
                    .stroke(Theme.Surface.line, lineWidth: 1)
                }
            }
            .frame(height: 72)

            bandCaptions(of: rhythm)
            hintCaptions(of: rhythm, hints: hints)
            key(of: rhythm, accent: accent)
        }
        // The key below names the colours, and the phase capsules further down
        // say the same thing as text, so VoiceOver gets a description rather
        // than a picture of one.
        .accessibilityHidden(true)
    }

    /// One ink's share of the line, in two passes: the segments the clock owns
    /// and the segments the person does. Dashing is a separate axis from colour
    /// — it marks an open-ended stage, where the durations describe a typical
    /// pass rather than a scheduled one.
    private func strokes(
        of rhythm: BreathRhythm,
        ink: RhythmInk,
        accent: Color,
        in size: CGSize
    ) -> some View {
        let colour = ink.colour(on: accent)

        return ZStack {
            RhythmGeometry.line(rhythm, in: size, inset: Self.lineWidth) { segment in
                RhythmInk(segment.kind) == ink && !segment.dashed
            }
            .stroke(
                colour,
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            )

            RhythmGeometry.line(rhythm, in: size, inset: Self.lineWidth) { segment in
                RhythmInk(segment.kind) == ink && segment.dashed
            }
            .stroke(
                colour,
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [4, 5])
            )
        }
    }

    /// "×30" under each stage that repeats, aligned to its band. Only drawn
    /// when there are stages to tell apart — a cyclic exercise's repeat count
    /// is already the headline of the length control.
    @ViewBuilder
    private func bandCaptions(of rhythm: BreathRhythm) -> some View {
        if rhythm.bands.count > 1 {
            GeometryReader { geometry in
                ForEach(Array(rhythm.bands.enumerated()), id: \.offset) { _, band in
                    if band.cycles > 1 {
                        Text("×\(band.cycles)")
                            .font(.caption2)
                            .foregroundStyle(Theme.Ink.tertiary)
                            .position(
                                x: (band.start + band.end) / 2 * geometry.size.width,
                                y: 7
                            )
                    }
                }
            }
            .frame(height: 14)
        }
    }

    /// "L R R L" under alternate-nostril's four breaths — the switching
    /// pattern at a glance, before the session spells it out. Initials rather
    /// than words because four segments share one row.
    @ViewBuilder
    private func hintCaptions(of rhythm: BreathRhythm, hints: [[String?]]?) -> some View {
        // All labels or none: the counts match today because the rhythm draws
        // one segment per phase per stage, but that is a drawing judgement,
        // not a contract — and a silently truncating zip would mislabel the
        // chart the day it changes.
        if let hints, hints.flatMap(\.self).count == rhythm.segments.count {
            let labelled = zip(rhythm.segments, hints.flatMap(\.self))

            GeometryReader { geometry in
                ForEach(Array(labelled.enumerated()), id: \.offset) { _, pair in
                    let (segment, hint) = pair
                    if let hint {
                        Text(hint.prefix(1))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(technique.goal.accent)
                            .position(
                                x: (segment.start + segment.end) / 2 * geometry.size.width,
                                y: 7
                            )
                    }
                }
            }
            .frame(height: 14)
        }
    }

    /// What the colours mean, in three words or fewer.
    ///
    /// The direction of the curve says it too, but only once you know to look;
    /// a dash of each colour beside its word is what makes the first glance
    /// legible. Deliberately not repeated in the list row, where there is no
    /// room and nothing to decide.
    private func key(of rhythm: BreathRhythm, accent: Color) -> some View {
        HStack(spacing: Theme.Spacing.standard) {
            ForEach(RhythmInk.present(in: rhythm), id: \.self) { ink in
                HStack(spacing: Theme.Spacing.tight) {
                    Capsule()
                        .fill(ink.colour(on: accent))
                        .frame(width: 12, height: 3)
                    Text(ink.word)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
