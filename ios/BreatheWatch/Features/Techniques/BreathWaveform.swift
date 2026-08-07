import BreatheKit
import BreatheUI
import SwiftUI

/// The carousel's artwork: the technique's own breathing pattern, drawn as a
/// line.
///
/// It replaced a coloured disc, which told you nothing — every technique got the
/// same circle in a different colour, so the picture carried no information at
/// all. A waveform carries the one thing worth knowing before you start: box
/// breathing is a square with four equal sides, 4-7-8 is a short rise and a long
/// fall, and a Wim Hof round is a fast ripple into a flat retention. You can
/// tell them apart at arm's length without reading anything.
///
/// The shape comes from `BreathRhythm`, which is where every judgement about
/// what the line shows already lives — one cycle per stage, widths proportional
/// to time with a floor so a fast stage cannot vanish beside a long one. This
/// view only turns those normalised coordinates into a path.
struct BreathWaveform: View {
    let technique: Technique
    let accent: Color

    private static let lineWidth: CGFloat = 3.5

    var body: some View {
        let rhythm = BreathRhythm(technique: technique)

        GeometryReader { geometry in
            let size = geometry.size

            // A wash under the line rather than a stroke alone: at this size on
            // a black screen the line by itself reads as thin and unfinished,
            // and the fill is what gives the page something to be about.
            path(rhythm, in: size, closed: true)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.45), accent.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            path(rhythm, in: size, closed: false)
                .stroke(
                    accent,
                    style: StrokeStyle(
                        lineWidth: Self.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        // Decoration. The name and the duration beside it carry the facts, and
        // a shape is not something VoiceOver can usefully describe.
        .accessibilityHidden(true)
    }

    /// The rhythm as one continuous line, optionally closed down to the baseline
    /// for the wash.
    ///
    /// No dashed/solid split, unlike the phone's chart: that distinction marks
    /// an open-ended stage, which is a caveat about scheduling and not something
    /// a wrist glances at artwork to learn — the caution screen and the session
    /// both say it in words. One pen stroke, start to finish.
    private func path(_ rhythm: BreathRhythm, in size: CGSize, closed: Bool) -> Path {
        Path { path in
            guard let first = rhythm.segments.first else { return }

            if closed {
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: point(x: first.start, level: first.startLevel, in: size))
            } else {
                path.move(to: point(x: first.start, level: first.startLevel, in: size))
            }

            for segment in rhythm.segments {
                let start = point(x: segment.start, level: segment.startLevel, in: size)
                let end = point(x: segment.end, level: segment.endLevel, in: size)

                switch segment.kind {
                case .inhale, .exhale:
                    // An S-curve, like the session orb's smoothstepped scale: a
                    // breath does not change pace at its boundaries.
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

            if closed {
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
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
