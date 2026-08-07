import OndKit
import SwiftUI

/// Places a `BreathLoop` in a frame and turns stretches of it into paths.
///
/// Shared by the detail screen's `BreathRhythmChart` and the list row's
/// `BreathRhythmMark` so the two can never disagree about the shape of an
/// exercise. They differ in size and in what they annotate; the loop itself is
/// built once, in `BreathKit`, and placed once, here.
enum RhythmGeometry {
    /// A stretch of the loop, between two fractions of the way round.
    static func line(
        of loop: BreathLoop,
        from start: Double,
        to end: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> Path {
        path(loop.polyline(from: start, to: end), in: size, inset: inset, closed: false)
    }

    /// The whole loop, closed, so the wash inside it is one region rather than
    /// one per phase.
    static func outline(of loop: BreathLoop, in size: CGSize, inset: CGFloat) -> Path {
        path(loop.outline, in: size, inset: inset, closed: true)
    }

    /// A point of the loop in the frame it is drawn in. The loop is square, so
    /// it takes the smaller dimension and sits in the middle of the other.
    static func place(_ point: CGPoint, in size: CGSize, inset: CGFloat) -> CGPoint {
        let side = min(size.width, size.height) - inset * 2
        return CGPoint(
            x: (size.width - side) / 2 + point.x * side,
            y: (size.height - side) / 2 + point.y * side
        )
    }

    private static func path(
        _ points: [CGPoint],
        in size: CGSize,
        inset: CGFloat,
        closed: Bool
    ) -> Path {
        Path { path in
            guard let first = points.first else { return }

            path.move(to: place(first, in: size, inset: inset))
            for point in points.dropFirst() {
                path.addLine(to: place(point, in: size, inset: inset))
            }
            if closed {
                path.closeSubpath()
            }
        }
    }
}
