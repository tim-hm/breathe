import CoreGraphics
import Foundation

/// One cycle of a stage as a closed loop — the path a finger would trace, once
/// round, to be back where it started.
///
/// A breath cycle repeats, and a line running left to right says otherwise: it
/// draws a beginning and an end where the exercise has neither. The loop says
/// the true thing, and it says it in the shape the exercise is named for — box
/// breathing is a box, and it is a box because its four phases are equal.
///
/// Three rules produce every drawing:
///
/// - **Corners are where the breath stops.** The track is a rounded square
///   whose corner radius falls as the cycle's hold share rises. An exercise
///   that never holds has nothing to stop for and draws as a circle; box
///   breathing, half of which is stillness, draws as a box; a retention hold,
///   which is nothing but stillness, draws as the hardest square here. The
///   silhouette carries a fact before a single colour is read.
/// - **Distance travelled is proportional to time.** A seven-second hold takes
///   up more of the loop than a four-second one, which is most of why the
///   drawing is worth looking at.
/// - **The lungs start empty at the bottom left and the loop runs clockwise**,
///   so an inhale climbs, the top is full lungs, and an exhale falls.
///
/// The happy consequence of the first two rules: the track's four quadrants are
/// congruent, so a quarter of its *length* is exactly a quarter turn, at every
/// corner radius including the circle. Four equal phases therefore land exactly
/// on the four corners, and box breathing is a box by arithmetic rather than by
/// special case.
///
/// Pure geometry, in a unit square with y downwards. The view scales it.
public struct BreathLoop: Sendable, Equatable {
    /// One phase's share of the loop, as the fraction of the way round it
    /// starts and ends.
    public struct Arc: Sendable, Equatable {
        public let kind: PhaseKind
        public let start: Double
        public let end: Double
        /// Whether the phase's length is the person's rather than the clock's.
        public let dashed: Bool

        public init(kind: PhaseKind, start: Double, end: Double, dashed: Bool) {
            self.kind = kind
            self.start = start
            self.end = end
            self.dashed = dashed
        }
    }

    /// The corner radius of a cycle that never holds: half the width, which is
    /// a circle.
    public static let roundest = 0.5
    /// The corner radius a cycle of nothing but held breath draws with. Not
    /// zero — a hard vertex reads as a chart axis, and every other surface in
    /// this app rounds its corners.
    public static let sharpest = 0.06
    /// How fast held time squares the loop. Steep enough that box breathing,
    /// which holds for half of its cycle, is unmistakably a box rather than a
    /// rounded rectangle.
    private static let squaring = 0.7

    public let arcs: [Arc]
    /// The track's corner radius as a fraction of its width, between
    /// `sharpest` and `roundest`.
    public let cornerRadius: Double
    /// How many times the stage repeats this loop. A caption, not a shape —
    /// thirty laps of one circle is one circle.
    public let cycles: Int

    /// The track, in travel order: nine straights and turns starting at the
    /// bottom-left corner's midpoint. Nine rather than eight because the
    /// starting corner is entered at its midpoint and so is split, which is
    /// exactly what puts a quarter of the loop's length at each corner.
    private let pieces: [Piece]
    private let perimeter: Double

    public init(stage: Stage) {
        let phases = stage.phases
        let total = max(stage.cycleDuration.seconds, 0.1)

        var arcs: [Arc] = []
        var travelled = 0.0
        var holding = 0.0

        for phase in phases {
            let share = phase.duration.seconds / total
            arcs.append(Arc(
                kind: phase.kind,
                start: travelled,
                end: travelled + share,
                dashed: stage.openEnded
            ))
            travelled += share
            if phase.kind == .holdIn || phase.kind == .holdOut {
                holding += share
            }
        }

        self.arcs = arcs
        cycles = stage.cycles
        cornerRadius = max(Self.sharpest, Self.roundest - Self.squaring * min(holding, 1))
        pieces = Self.track(cornerRadius: cornerRadius)
        perimeter = pieces.reduce(0) { $0 + $1.length }
    }

    /// The whole loop, closed, for filling.
    public var outline: [CGPoint] {
        polyline(from: 0, to: 1)
    }

    /// The point a given fraction of the way round.
    public func point(at fraction: Double) -> CGPoint {
        let distance = min(max(fraction, 0), 1) * perimeter
        var remaining = distance

        for piece in pieces {
            if remaining <= piece.length {
                return piece.point(at: piece.length > 0 ? remaining / piece.length : 0)
            }
            remaining -= piece.length
        }
        return pieces[pieces.count - 1].point(at: 1)
    }

    /// The stretch of the loop between two fractions, as a polyline.
    ///
    /// The ends land exactly on the fractions asked for rather than on the
    /// nearest sample, so one phase's arc starts precisely where the last one
    /// finished. A gap of a third of a degree is invisible in isolation and an
    /// obvious nick in a 2pt stroke.
    public func polyline(from start: Double, to end: Double) -> [CGPoint] {
        let first = min(max(start, 0), 1) * perimeter
        let last = min(max(end, 0), 1) * perimeter
        guard last > first else { return [] }

        var points: [CGPoint] = []
        var offset = 0.0

        for piece in pieces {
            let pieceEnd = offset + piece.length
            defer { offset = pieceEnd }
            guard piece.length > 0, pieceEnd > first, offset < last else { continue }

            let from = max(first - offset, 0) / piece.length
            let to = min(last - offset, piece.length) / piece.length
            for point in piece.polyline(from: from, to: to) where points.last != point {
                points.append(point)
            }
        }

        return points
    }

    /// A rounded square inscribed in the unit box, walked clockwise from the
    /// midpoint of its bottom-left corner — where the lungs are empty and the
    /// climb is about to start.
    ///
    /// Angles are measured in the drawing's own frame, y downwards, so they
    /// increase all the way round: 135° at the start, 495° back at it.
    private static func track(cornerRadius radius: Double) -> [Piece] {
        let near = radius
        let far = 1 - radius
        let turn = Double.pi / 2

        let bottomLeft = CGPoint(x: near, y: far)
        let topLeft = CGPoint(x: near, y: near)
        let topRight = CGPoint(x: far, y: near)
        let bottomRight = CGPoint(x: far, y: far)

        return [
            .turn(centre: bottomLeft, radius: radius, from: 1.5 * turn, to: 2 * turn),
            .edge(from: CGPoint(x: 0, y: far), to: CGPoint(x: 0, y: near)),
            .turn(centre: topLeft, radius: radius, from: 2 * turn, to: 3 * turn),
            .edge(from: CGPoint(x: near, y: 0), to: CGPoint(x: far, y: 0)),
            .turn(centre: topRight, radius: radius, from: 3 * turn, to: 4 * turn),
            .edge(from: CGPoint(x: 1, y: near), to: CGPoint(x: 1, y: far)),
            .turn(centre: bottomRight, radius: radius, from: 4 * turn, to: 5 * turn),
            .edge(from: CGPoint(x: far, y: 1), to: CGPoint(x: near, y: 1)),
            .turn(centre: bottomLeft, radius: radius, from: 5 * turn, to: 5.5 * turn),
        ]
    }
}

/// One straight or one turn of the track, able to place a point at any distance
/// along itself. Splitting the track into pieces with closed-form lengths is
/// what makes "a fraction of the way round" exact rather than the result of
/// walking a few hundred samples and hoping they were dense enough — and the
/// flats of a squared-off loop are exactly where a sampled parametrisation
/// thins out worst.
private enum Piece: Sendable, Equatable {
    case edge(from: CGPoint, to: CGPoint)
    case turn(centre: CGPoint, radius: Double, from: Double, to: Double)

    /// A turn is drawn as a fan of chords this many radians apart. Three
    /// degrees is smooth at every size this is drawn at, from a 40pt row mark
    /// to a full-width chart.
    private static let step = Double.pi / 60

    var length: Double {
        switch self {
        case let .edge(from, to):
            Double(hypot(to.x - from.x, to.y - from.y))
        case let .turn(_, radius, from, to):
            (to - from) * radius
        }
    }

    func point(at t: Double) -> CGPoint {
        switch self {
        case let .edge(from, to):
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        case let .turn(centre, radius, from, to):
            let angle = from + (to - from) * t
            return CGPoint(
                x: centre.x + radius * cos(angle),
                y: centre.y + radius * sin(angle)
            )
        }
    }

    func polyline(from start: Double, to end: Double) -> [CGPoint] {
        switch self {
        case .edge:
            return [point(at: start), point(at: end)]
        case let .turn(_, _, from, to):
            let sweep = (to - from) * (end - start)
            let steps = max(Int((sweep / Self.step).rounded(.up)), 1)
            return (0 ... steps).map { step in
                point(at: start + (end - start) * Double(step) / Double(steps))
            }
        }
    }
}

public extension Technique {
    /// One loop per stage, in play order.
    var loops: [BreathLoop] {
        stages.map(BreathLoop.init(stage:))
    }
}
