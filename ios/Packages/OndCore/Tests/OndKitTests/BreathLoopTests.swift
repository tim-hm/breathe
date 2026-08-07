import CoreGraphics
import Foundation
import OndKit
import Testing

/// The loop is the picture of an exercise on two screens, and nothing else
/// checks it: a corner in the wrong place draws box breathing as an oval, and a
/// phase given the wrong share of the track tells a plain lie about how long a
/// hold lasts.
@Suite("Drawing a stage as a closed loop")
struct BreathLoopTests {
    private func phase(_ kind: PhaseKind, seconds: Double) -> Phase {
        Phase(kind: kind, duration: .milliseconds(Int(seconds * 1000)))
    }

    private func boxBreathing(cycles: Int = 8) -> Stage {
        Stage(
            phases: [
                phase(.inhale, seconds: 4),
                phase(.holdIn, seconds: 4),
                phase(.exhale, seconds: 4),
                phase(.holdOut, seconds: 4),
            ],
            cycles: cycles
        )
    }

    private func length(of points: [CGPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst())
            .reduce(0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) }
    }

    private func distanceFromCentre(_ point: CGPoint) -> Double {
        Double(hypot(point.x - 0.5, point.y - 0.5))
    }

    /// The claim the whole design rests on: four equal phases put a phase
    /// boundary exactly on each corner, so the exercise called box breathing
    /// draws a box.
    @Test("Box breathing turns a corner on every phase boundary")
    func boxBreathingCorners() {
        let loop = BreathLoop(stage: boxBreathing())
        let radius = loop.cornerRadius
        let inset = radius - radius / 2.squareRoot()

        #expect(loop.arcs.count == 4)
        #expect(loop.arcs.allSatisfy { abs(($0.end - $0.start) - 0.25) < 1e-12 })

        let corners = [
            CGPoint(x: inset, y: 1 - inset),
            CGPoint(x: inset, y: inset),
            CGPoint(x: 1 - inset, y: inset),
            CGPoint(x: 1 - inset, y: 1 - inset),
        ]
        for (index, corner) in corners.enumerated() {
            let point = loop.point(at: Double(index) * 0.25)
            #expect(abs(point.x - corner.x) < 1e-9)
            #expect(abs(point.y - corner.y) < 1e-9)
        }
    }

    /// The reading the colours depend on: start empty, climb, and come back
    /// down the other side.
    @Test("The loop starts with empty lungs at the bottom left and climbs")
    func direction() {
        let loop = BreathLoop(stage: boxBreathing())

        let start = loop.point(at: 0)
        #expect(start.x < 0.25)
        #expect(start.y > 0.75)

        // Part way up the inhale, the line has risen and not yet crossed the
        // middle of the track.
        let climbing = loop.point(at: 0.125)
        #expect(climbing.y < start.y)
        #expect(climbing.x < 0.5)

        // Part way down the exhale, on the far side and falling again.
        let falling = loop.point(at: 0.625)
        #expect(falling.x > 0.5)
        #expect(falling.y > loop.point(at: 0.5).y)
    }

    /// An exercise with nothing to stop for has no corners at all.
    @Test("A cycle that never holds draws as a circle")
    func noHolds() {
        let loop = BreathLoop(stage: Stage(
            phases: [phase(.inhale, seconds: 5.5), phase(.exhale, seconds: 5.5)],
            cycles: 10
        ))

        #expect(loop.cornerRadius == BreathLoop.roundest)
        #expect(loop.outline.allSatisfy { abs(distanceFromCentre($0) - 0.5) < 1e-9 })
    }

    @Test("A retention hold draws as the hardest square, and dashed throughout")
    func retention() {
        let loop = BreathLoop(stage: Stage(
            phases: [phase(.holdOut, seconds: 90)],
            cycles: 1,
            openEnded: true
        ))

        // Bound rather than written inline: the formatter rewrites the closure
        // to a key path, and a key path inside `#expect` resolves to the
        // throwing overload and stops compiling.
        let everyArcDashed = loop.arcs.allSatisfy(\.dashed)

        #expect(loop.cornerRadius == BreathLoop.sharpest)
        #expect(everyArcDashed)
        // The circle test's invariant, inverted: a square's corners stand a
        // long way further from the centre than the middles of its edges do,
        // where a circle's points all stand at one distance. Walked rather
        // than read off `outline`, which carries no mid-edge point — a
        // straight run needs only its two ends to draw.
        let reach = stride(from: 0.0, to: 1.0, by: 0.005)
            .map { distanceFromCentre(loop.point(at: $0)) }
        #expect((reach.max() ?? 0) / (reach.min() ?? 1) > 1.3)
    }

    /// Uneven phases are the case the corners cannot flatter: 4-7-8 is not a
    /// box, and the drawing has to say so.
    @Test("Phases take the share of the loop their durations earn")
    func unevenPhases() {
        let loop = BreathLoop(stage: Stage(
            phases: [
                phase(.inhale, seconds: 4),
                phase(.holdIn, seconds: 7),
                phase(.exhale, seconds: 8),
            ],
            cycles: 4
        ))

        let shares = loop.arcs.map { $0.end - $0.start }
        #expect(abs(shares[0] - 4.0 / 19) < 1e-12)
        #expect(abs(shares[1] - 7.0 / 19) < 1e-12)
        #expect(abs(shares[2] - 8.0 / 19) < 1e-12)
        #expect(abs((loop.arcs.last?.end ?? 0) - 1) < 1e-12)

        // Nothing about a rounded square makes equal shares equal distances for
        // free: the drawn line has to be measured.
        let drawn = loop.arcs.map { length(of: loop.polyline(from: $0.start, to: $0.end)) }
        #expect(abs(drawn[1] / drawn[0] - 7.0 / 4) < 0.01)
        #expect(abs(drawn[2] / drawn[0] - 8.0 / 4) < 0.01)
    }

    /// Each phase is stroked as its own path, so they have to meet: a rounding
    /// difference between one arc's end and the next one's start is a visible
    /// nick in the line.
    @Test("Consecutive phases begin exactly where the last one ended")
    func arcsMeet() {
        let loop = BreathLoop(stage: Stage(
            phases: [
                phase(.inhale, seconds: 1.5),
                phase(.inhale, seconds: 0.5),
                phase(.exhale, seconds: 5),
            ],
            cycles: 6
        ))

        for (earlier, later) in zip(loop.arcs, loop.arcs.dropFirst()) {
            let ends = loop.polyline(from: earlier.start, to: earlier.end).last
            let begins = loop.polyline(from: later.start, to: later.end).first
            #expect(abs((ends?.x ?? 0) - (begins?.x ?? 1)) < 1e-12)
            #expect(abs((ends?.y ?? 0) - (begins?.y ?? 1)) < 1e-12)
        }
    }

    @Test("A technique draws one loop per stage, carrying its repeat count")
    func stages() {
        let technique = Technique(
            id: "id",
            slug: "wim-hof",
            name: "Name",
            summary: "",
            goal: .energy,
            stages: [
                Stage(
                    phases: [phase(.inhale, seconds: 1.5), phase(.exhale, seconds: 1.5)],
                    cycles: 30
                ),
                Stage(phases: [phase(.holdOut, seconds: 90)], cycles: 1, openEnded: true),
            ],
            recommendedRounds: 3
        )

        #expect(technique.loops.map(\.cycles) == [30, 1])
        #expect(technique.loops[0].cornerRadius == BreathLoop.roundest)
        #expect(technique.loops[1].cornerRadius == BreathLoop.sharpest)
    }
}
