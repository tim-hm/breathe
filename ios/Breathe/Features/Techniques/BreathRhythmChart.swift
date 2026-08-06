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

        VStack(spacing: Theme.Spacing.tight) {
            GeometryReader { geometry in
                let size = geometry.size

                area(of: rhythm, in: size)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.2), accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                line(of: rhythm, in: size, dashed: false)
                    .stroke(
                        accent,
                        style: StrokeStyle(
                            lineWidth: Self.lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                line(of: rhythm, in: size, dashed: true)
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
        }
        // The phase capsules directly below say the same thing as text, so
        // VoiceOver gets one description instead of a picture of it.
        .accessibilityHidden(true)
    }

    /// The rhythm's line. Solid and dashed segments are separate paths because
    /// one stroke style applies per path — the pen still travels through every
    /// segment so each piece starts where the previous one ended.
    private func line(of rhythm: BreathRhythm, in size: CGSize, dashed: Bool) -> Path {
        Path { path in
            for segment in rhythm.segments {
                let start = point(x: segment.start, level: segment.startLevel, in: size)
                let end = point(x: segment.end, level: segment.endLevel, in: size)

                if segment.dashed != dashed {
                    path.move(to: end)
                    continue
                }
                if path.currentPoint == nil || path.currentPoint != start {
                    path.move(to: start)
                }

                switch segment.kind {
                case .inhale, .exhale:
                    // An S-curve, like the orb's smoothstepped scale: a breath
                    // does not change pace at its boundaries.
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
        }
    }

    /// The full line regardless of dashing, closed down to the baseline, so
    /// the wash under the curve never splits where the stroke does.
    private func area(of rhythm: BreathRhythm, in size: CGSize) -> Path {
        var path = Path()
        guard let first = rhythm.segments.first else { return path }

        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: point(x: first.start, level: first.startLevel, in: size))
        for segment in rhythm.segments {
            let end = point(x: segment.end, level: segment.endLevel, in: size)
            switch segment.kind {
            case .inhale, .exhale:
                let start = point(x: segment.start, level: segment.startLevel, in: size)
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
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
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

    /// Normalised rhythm coordinates to points. The vertical inset keeps a
    /// full-lung plateau's stroke inside the frame instead of shaving its top
    /// half off.
    private func point(x: Double, level: Double, in size: CGSize) -> CGPoint {
        let inset = Self.lineWidth
        return CGPoint(
            x: x * size.width,
            y: inset + (1 - level) * (size.height - inset * 2)
        )
    }
}
