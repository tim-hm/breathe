import BreatheKit
import SwiftUI

/// Path building for a breathing rhythm's line and the wash under it.
///
/// Shared by the detail screen's `BreathRhythmChart` and the list row's
/// `BreathRhythmMark` so the two can never disagree about the shape of an
/// exercise. They differ in size and in what they annotate; the curve itself is
/// built once, here.
enum RhythmGeometry {
    /// The rhythm's line, restricted to the segments `isDrawn` accepts.
    ///
    /// One stroke style applies per path, so a line drawn in three inks and two
    /// dash patterns is six paths over the same rhythm. The pen still travels
    /// through every segment — moving rather than drawing the ones it is not
    /// asked for — which is what makes each piece start exactly where the
    /// previous one ended instead of a fraction off.
    static func line(
        _ rhythm: BreathRhythm,
        in size: CGSize,
        inset: CGFloat,
        including isDrawn: (BreathRhythm.Segment) -> Bool
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

                guard isDrawn(segment) else {
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

    /// The whole line, closed down to the baseline, so the wash under the curve
    /// never splits where the stroke does.
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
            // An S-curve, like the orb's smoothstepped scale: a breath does not
            // change pace at its boundaries.
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
