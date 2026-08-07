import CoreGraphics
import Foundation

/// One cycle of a stage that holds, drawn as a closed polygon with a corner at
/// every phase boundary.
///
/// **Corners are where the breath stops.** A cycle that pauses has real corners
/// to draw, and putting one on each phase boundary is what makes box breathing a
/// box: four equal phases put four vertices a quarter-turn apart, so the figure
/// the exercise is named for falls out of arithmetic rather than a special case.
/// Three phases give a triangle, and 4-7-8's are 4:7:8, so its triangle is
/// visibly scalene.
///
/// Vertices sit on a circle at angles proportional to *cumulative* phase time,
/// walked clockwise from empty lungs at the bottom left. Angles rather than side
/// lengths, and the distinction is load-bearing: a polygon whose sides were
/// literally proportional to duration is not always constructible. 4-7-8's dials
/// reach in 3 / hold 4 / out 12, and `3 + 4 < 12` — no triangle has those sides.
/// Placing vertices on a circle always closes, keeps every corner on a phase
/// boundary, and still grows a side with the phase it belongs to, because a
/// wider angular span subtends a longer chord.
///
/// Pure geometry, in a unit square with y downwards. The view scales it.
public struct BreathPolygon: Sendable, Equatable {
    /// One phase, as the run of the outline it owns.
    public struct Side: Sendable, Equatable {
        public let kind: PhaseKind
        /// Whether the phase's length is the person's rather than the clock's.
        public let dashed: Bool
        /// The straight run, after the corner it leaves and before the one it
        /// enters.
        public let from: CGPoint
        public let to: CGPoint
        /// The corner this side leaves, and the corner it enters — each already
        /// split in half, so the two phases meeting at a vertex own one half
        /// each and neither colour bleeds across the turn.
        public let leaving: Corner
        public let entering: Corner

        /// The point a label for this side hangs off: the middle of the straight
        /// run.
        public var midpoint: CGPoint {
            CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        }
    }

    /// Half a rounded corner, as a quadratic curve.
    public struct Corner: Sendable, Equatable {
        /// The midpoint of the full corner curve, where the two halves meet.
        public let middle: CGPoint
        public let control: CGPoint
        /// Where the straight run on the far side of this half begins or ends.
        public let edge: CGPoint
    }

    /// The floor under a phase's share of the turn. Below about twenty degrees
    /// two vertices are close enough that the side between them reads as a nick
    /// in the outline rather than a phase, and the physiological sigh's 0.7
    /// second sip would sit well under it.
    public static let minimumShare = 0.055

    /// How far back from a vertex the straight run stops, as a fraction of the
    /// shorter of the two sides meeting there. Every other surface in the app
    /// rounds its corners; a hard vertex here would read as a chart axis.
    private static let cornerTrim = 0.16
    /// The ceiling on that trim in unit-square terms, so a figure with one very
    /// long side does not round it into an arc.
    private static let maximumTrim = 0.09

    /// The phase boundaries, in play order, starting at empty lungs.
    public let vertices: [CGPoint]
    /// One per phase, in play order.
    public let sides: [Side]
    /// Where the breath starts — the first vertex, at empty lungs.
    public var start: CGPoint {
        vertices.first ?? CGPoint(x: 0.5, y: 1)
    }

    /// The closed outline, for the wash a renderer lays inside the figure.
    ///
    /// Built from the sides rather than reassembled from their strokes: a
    /// renderer that stitched the strokes back together would depend on each
    /// one starting with a `move`, and on being able to tell a closed figure
    /// from an open line by counting them.
    public var outline: [TechniqueFigure.Command] {
        guard let first = sides.first else { return [] }

        var commands: [TechniqueFigure.Command] = [.move(to: first.leaving.middle)]
        for side in sides {
            commands.append(.quadCurve(to: side.from, control: side.leaving.control))
            commands.append(.line(to: side.to))
            commands.append(.quadCurve(to: side.entering.middle, control: side.entering.control))
        }
        return commands
    }

    /// Whether this stage should be drawn as a polygon at all.
    ///
    /// A cycle with no hold has nothing to stop for, and a cycle of one phase
    /// has no boundary to put a corner on. Both belong to the line families;
    /// asking this rather than inspecting the stage at every call site is what
    /// keeps that decision in one place.
    public static func suits(_ stage: Stage) -> Bool {
        stage.phases.count >= 3 && stage.phases.contains { $0.kind.isHold }
    }

    public init(stage: Stage) {
        let phases = stage.phases
        let shares = ProportionalShares.of(
            phases.map { max($0.duration.seconds, 0.001) },
            floor: Self.minimumShare
        )

        // 135° with y downwards is the bottom-left of the circle, and angles
        // increase clockwise from there. That start puts box breathing's four
        // vertices on the four corners of an upright square — in up the left
        // side, hold across the top, out down the right, hold along the bottom,
        // which is the figure the marketing site draws and the order the labels
        // read in.
        var angle = Double.pi * 0.75
        var vertices: [CGPoint] = []
        for share in shares {
            vertices.append(Self.place(angle: angle))
            angle += share * 2 * .pi
        }

        self.vertices = vertices
        sides = Self.sides(around: vertices, phases: phases, dashed: stage.openEnded)
    }

    /// A point on the circle inscribed in the unit square.
    private static func place(angle: Double) -> CGPoint {
        CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
    }

    private static func sides(
        around vertices: [CGPoint],
        phases: [Phase],
        dashed: Bool
    ) -> [Side] {
        let count = vertices.count
        guard count > 1, phases.count == count else { return [] }

        // Trims are computed for every vertex before any side is built: a
        // corner is shared by two sides, and one that trimmed itself per side
        // would round the same vertex by two different amounts.
        let trims = (0 ..< count).map { index -> Double in
            let previous = vertices[(index + count - 1) % count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % count]
            let shorter = min(distance(previous, vertex), distance(vertex, next))
            return min(shorter * cornerTrim, maximumTrim)
        }

        // Each corner is split at its own midpoint so the two phases meeting
        // there own one half each. Without the split the turn would take the
        // colour of whichever phase happened to draw it, and on box breathing
        // that is a visible smudge of inhale at the top-left of the hold.
        let halves = (0 ..< count).map { index -> (into: Corner, outOf: Corner) in
            let previous = vertices[(index + count - 1) % count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % count]
            let entry = step(from: vertex, towards: previous, by: trims[index])
            let exit = step(from: vertex, towards: next, by: trims[index])
            let middle = CGPoint(
                x: 0.25 * entry.x + 0.5 * vertex.x + 0.25 * exit.x,
                y: 0.25 * entry.y + 0.5 * vertex.y + 0.25 * exit.y
            )

            return (
                into: Corner(middle: middle, control: midpoint(entry, vertex), edge: entry),
                outOf: Corner(middle: middle, control: midpoint(vertex, exit), edge: exit)
            )
        }

        return phases.indices.map { index in
            let next = (index + 1) % count
            return Side(
                kind: phases[index].kind,
                dashed: dashed,
                from: halves[index].outOf.edge,
                to: halves[next].into.edge,
                leaving: halves[index].outOf,
                entering: halves[next].into
            )
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(b.x - a.x, b.y - a.y))
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// A point `by` along the way from `point` towards `target`.
    private static func step(from point: CGPoint, towards target: CGPoint, by: Double) -> CGPoint {
        let reach = distance(point, target)
        guard reach > 0 else { return point }
        let fraction = min(by / reach, 0.5)
        return CGPoint(
            x: point.x + (target.x - point.x) * fraction,
            y: point.y + (target.y - point.y) * fraction
        )
    }
}
