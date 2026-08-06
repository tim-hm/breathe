import BreatheKit
import BreatheUI
import SwiftUI

/// The technique's rhythm as a line — lung fullness across one round, drawn
/// from the same dialled values the session will play. Because it reads the
/// dialled technique, it redraws live as the Advanced dials move, which is
/// half the point: the exhale visibly lengthens while the person drags it.
struct BreathRhythmChart: View {
    /// The dialled technique, not the curated one — the chart is a preview of
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

                RhythmGeometry.line(rhythm, in: size, dashed: false, inset: Self.lineWidth)
                    .stroke(
                        accent,
                        style: StrokeStyle(
                            lineWidth: Self.lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                RhythmGeometry.line(rhythm, in: size, dashed: true, inset: Self.lineWidth)
                    .stroke(
                        accent.opacity(0.7),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [4, 5])
                    )

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
        }
        // The phase capsules directly below say the same thing as text, so
        // VoiceOver gets one description instead of a picture of it.
        .accessibilityHidden(true)
    }

    /// "×30" under each stage that repeats, aligned to its band. Only drawn
    /// when there are stages to tell apart — a cyclic technique's repeat count
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
        if let hints {
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
}

/// The rhythm at row scale: the same line the detail screen draws, small
/// enough to sit at the trailing edge of a catalogue card. No captions, no
/// area wash — at this size the line is the whole message.
struct BreathRhythmSparkline: View {
    let technique: Technique

    private static let lineWidth: CGFloat = 1.5

    var body: some View {
        let rhythm = BreathRhythm(technique: technique)
        let accent = technique.goal.accent

        GeometryReader { geometry in
            RhythmGeometry.line(rhythm, in: geometry.size, dashed: false, inset: Self.lineWidth)
                .stroke(
                    accent.opacity(0.85),
                    style: StrokeStyle(
                        lineWidth: Self.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            RhythmGeometry.line(rhythm, in: geometry.size, dashed: true, inset: Self.lineWidth)
                .stroke(
                    accent.opacity(0.5),
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [3, 4])
                )
        }
        .frame(width: 64, height: 28)
        // Decoration for the row it sits in; the row's text carries the facts.
        .accessibilityHidden(true)
    }
}

/// Path building shared by the chart and the sparkline, so the two can never
/// draw the same technique differently.
private enum RhythmGeometry {
    /// The rhythm's line. Solid and dashed segments are separate paths because
    /// one stroke style applies per path — the pen still travels through every
    /// segment so each piece starts where the previous one ended.
    static func line(
        _ rhythm: BreathRhythm,
        in size: CGSize,
        dashed: Bool,
        inset: CGFloat
    ) -> Path {
        Path { path in
            for segment in rhythm.segments {
                let start = point(
                    x: segment.start,
                    level: segment.startLevel,
                    in: size,
                    inset: inset
                )
                let end = point(x: segment.end, level: segment.endLevel, in: size, inset: inset)

                if segment.dashed != dashed {
                    path.move(to: end)
                    continue
                }
                if path.currentPoint != start {
                    path.move(to: start)
                }

                add(segment, from: start, to: end, into: &path)
            }
        }
    }

    /// The full line regardless of dashing, closed down to the baseline, so
    /// the wash under the curve never splits where the stroke does.
    static func area(_ rhythm: BreathRhythm, in size: CGSize, inset: CGFloat) -> Path {
        var path = Path()
        guard let first = rhythm.segments.first else { return path }

        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: point(x: first.start, level: first.startLevel, in: size, inset: inset))
        for segment in rhythm.segments {
            let start = point(x: segment.start, level: segment.startLevel, in: size, inset: inset)
            let end = point(x: segment.end, level: segment.endLevel, in: size, inset: inset)
            add(segment, from: start, to: end, into: &path)
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private static func add(
        _ segment: BreathRhythm.Segment,
        from start: CGPoint,
        to end: CGPoint,
        into path: inout Path
    ) {
        switch segment.kind {
        case .inhale, .exhale:
            // An S-curve, like the orb's smoothstepped scale: a breath does
            // not change pace at its boundaries.
            let middle = (start.x + end.x) / 2
            path.addCurve(
                to: end,
                control1: CGPoint(x: middle, y: start.y),
                control2: CGPoint(x: middle, y: end.y)
            )
        case .holdIn, .holdOut:
            path.addLine(to: end)
        }
    }

    /// Normalised rhythm coordinates to points. The vertical inset keeps a
    /// full-lung plateau's stroke inside the frame instead of shaving its top
    /// half off.
    private static func point(
        x: Double,
        level: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: x * size.width,
            y: inset + (1 - level) * (size.height - inset * 2)
        )
    }
}
