import CoreGraphics
import Foundation
import OndKit
import Testing

/// The figure is what a person reads before deciding to breathe something, and
/// nothing else validates it. The grammar this replaced drew five of the nine
/// seeded techniques as an identical circle — coherent breathing and bellows
/// breath, 5½ breaths a minute and twenty fast ones, were the same picture. Most
/// of what follows exists so that cannot come back.
@Suite("Drawing a technique as a figure")
struct TechniqueFigureTests {
    private func figure(_ slug: String, stage: Int = 0) -> TechniqueFigure {
        let figures = TechniqueFigure.all(for: SeededCatalogue.technique(slug))
        return figures[stage]
    }

    /// Every point a stroke passes through, for measuring a silhouette without
    /// caring which command drew it.
    private func points(of figure: TechniqueFigure) -> [CGPoint] {
        figure.strokes.filter { $0.role != .baseline }.flatMap { stroke in
            stroke.commands.compactMap { command in
                switch command {
                case let .move(point), let .line(point): point
                case let .quadCurve(point, _): point
                case let .curve(point, _, _): point
                case .circle: nil
                }
            }
        }
    }

    // MARK: Family selection

    /// The rule the whole grammar rests on. A technique that lands in the wrong
    /// family is not a slightly-off drawing, it is a different kind of drawing.
    @Test(
        "A cycle that holds draws as a polygon and one that does not draws as a line",
        arguments: [
            ("box-breathing", true),
            ("long-box-breathing", true),
            ("four-seven-eight", true),
            ("coherent-breathing", false),
            ("bellows-breath", false),
            ("extended-exhale", false),
            ("physiological-sigh", false),
            ("alternate-nostril", false),
        ]
    )
    func familySelection(slug: String, isPolygon: Bool) {
        #expect(figure(slug).family == (isPolygon ? .polygon : .line), "`\(slug)`")
    }

    /// A wash belongs inside a closed figure and nowhere else. Asserted because
    /// it was wrong: `fill` used to infer "closed" from a stroke count, and
    /// every hold-free technique picked up a gradient across a path it does not
    /// draw — while the site, reading the same geometry, drew none.
    @Test("Only a polygon encloses anything to fill")
    func onlyPolygonsFill() {
        for technique in SeededCatalogue.techniques {
            for drawn in TechniqueFigure.all(for: technique) {
                #expect(
                    drawn.fill.isEmpty == (drawn.family == .line),
                    "`\(technique.slug)` \(drawn.family)"
                )
            }
        }
    }

    /// The only staged technique in the catalogue, and the only one that mixes
    /// families: fast breathing, a retention nobody times, then a recovery hold
    /// that has corners again.
    @Test("A Wim Hof round draws three figures, and only the middle one is dashed")
    func wimHofRounds() {
        let figures = TechniqueFigure.all(for: SeededCatalogue.technique("wim-hof-rounds"))

        #expect(figures.count == 3)
        #expect(!figures[0].strokes.contains { $0.dashed })
        #expect(figures[1].strokes.contains { $0.dashed })
        #expect(!figures[2].strokes.contains { $0.dashed })

        // The recovery stage holds, so it is the triangle; the fast stage does
        // not, so it is a line.
        #expect(figures[0].family == .line)
        #expect(figures[2].family == .polygon)
    }

    // MARK: The polygon

    /// The claim box breathing's name makes. Four equal phases put four vertices
    /// a quarter-turn apart, so the figure is a square by arithmetic — and the
    /// four sides run in, hold, out, hold, which is the order the labels read.
    @Test("Box breathing is a square with a corner on every phase boundary")
    func boxBreathingIsASquare() {
        let polygon = BreathPolygon(stage: SeededCatalogue.technique("box-breathing").stages[0])

        #expect(polygon.vertices.count == 4)

        // Bottom-left, top-left, top-right, bottom-right — an upright square,
        // not a diamond. The inhale therefore climbs the left side.
        let corner = 0.5 / 2.0.squareRoot()
        let expected = [
            CGPoint(x: 0.5 - corner, y: 0.5 + corner),
            CGPoint(x: 0.5 - corner, y: 0.5 - corner),
            CGPoint(x: 0.5 + corner, y: 0.5 - corner),
            CGPoint(x: 0.5 + corner, y: 0.5 + corner),
        ]

        for (vertex, expected) in zip(polygon.vertices, expected) {
            #expect(abs(vertex.x - expected.x) < 1e-9)
            #expect(abs(vertex.y - expected.y) < 1e-9)
        }

        #expect(polygon.sides.map(\.kind) == [.inhale, .holdIn, .exhale, .holdOut])
    }

    /// Three phases, three corners. The old grammar drew this as a rounded
    /// rectangle, which said "a bit like box breathing" about an exercise whose
    /// phases are 4:7:8 and which has no second hold at all.
    @Test("4-7-8 is a triangle whose corners fall where its phases end")
    func fourSevenEightIsATriangle() {
        let polygon = BreathPolygon(stage: SeededCatalogue.technique("four-seven-eight").stages[0])

        #expect(polygon.vertices.count == 3)
        #expect(polygon.sides.map(\.kind) == [.inhale, .holdIn, .exhale])

        // Vertices sit at the cumulative share of the cycle each phase starts
        // at: 0, 4/19, 11/19 of a turn from the bottom left.
        let start = Double.pi * 0.75
        for (index, share) in [0.0, 4.0 / 19, 11.0 / 19].enumerated() {
            let angle = start + share * 2 * .pi
            #expect(abs(polygon.vertices[index].x - (0.5 + 0.5 * cos(angle))) < 1e-9)
            #expect(abs(polygon.vertices[index].y - (0.5 + 0.5 * sin(angle))) < 1e-9)
        }
    }

    /// The case that kills the obvious construction. A polygon whose sides were
    /// literally proportional to duration cannot exist here — `3 + 4 < 12`
    /// violates the triangle inequality — and these are dial positions the
    /// catalogue allows, not hypotheticals.
    @Test("A 4-7-8 dialled to its extremes still closes")
    func extremeDialsStillConstruct() {
        let stage = Stage(
            phases: [
                Phase(kind: .inhale, duration: .seconds(3)),
                Phase(kind: .holdIn, duration: .seconds(4)),
                Phase(kind: .exhale, duration: .seconds(12)),
            ],
            cycles: 4
        )
        let polygon = BreathPolygon(stage: stage)

        #expect(polygon.vertices.count == 3)
        // Every vertex on the circle inscribed in the unit box, so the figure
        // is inside its frame however lopsided the durations are.
        for vertex in polygon.vertices {
            #expect(abs(hypot(vertex.x - 0.5, vertex.y - 0.5) - 0.5) < 1e-9)
        }
        // And distinct, so no side has collapsed to a point.
        #expect(hypot(
            polygon.vertices[0].x - polygon.vertices[1].x,
            polygon.vertices[0].y - polygon.vertices[1].y
        ) > 0.1)
    }

    /// The two box exercises are the same ratios at different lengths, so the
    /// same silhouette is the honest answer — and the labels are what tell them
    /// apart.
    @Test("Long box breathing is the same square, labelled with its own counts")
    func longBoxIsTheSameSquare() {
        let box = BreathPolygon(stage: SeededCatalogue.technique("box-breathing").stages[0])
        let long = BreathPolygon(stage: SeededCatalogue.technique("long-box-breathing").stages[0])

        #expect(box.vertices == long.vertices)
        #expect(figure("box-breathing").labels.map(\.text).contains("in · 4"))
        #expect(figure("long-box-breathing").labels.map(\.text).contains("in · 6"))
    }

    // MARK: The line

    /// The collision this whole change exists to fix. Both are one-to-one with
    /// no holds, so slope cannot separate them and the old corner-radius rule
    /// gave them the same circle. Only tempo distinguishes them, and tempo is
    /// what drawing a fixed span of time puts on the page.
    @Test("Coherent breathing and bellows breath draw different pictures")
    func coherentIsNotBellows() {
        let coherent = BreathRhythm(stage: SeededCatalogue.technique("coherent-breathing")
            .stages[0])
        let bellows = BreathRhythm(stage: SeededCatalogue.technique("bellows-breath").stages[0])

        #expect(coherent.cycles == 2)
        #expect(bellows.cycles == 11)
        #expect(coherent.segments.count != bellows.segments.count)
    }

    /// Slope is the channel that makes a line worth looking at: a four-second
    /// rise beside a six-second fall should be visibly steeper, in exactly the
    /// ratio of the two durations.
    @Test("Extended exhale falls more gently than it rises, in the ratio of its phases")
    func extendedExhaleSlopes() {
        let rhythm = BreathRhythm(stage: SeededCatalogue.technique("extended-exhale").stages[0])
        let rise = rhythm.segments[0]
        let fall = rhythm.segments[1]

        #expect(rise.kind == .inhale)
        #expect(fall.kind == .exhale)

        let rising = abs(rise.endLevel - rise.startLevel) / (rise.end - rise.start)
        let falling = abs(fall.endLevel - fall.startLevel) / (fall.end - fall.start)

        #expect(rising > falling)
        // 4 seconds in against 6 out, so the fall is two-thirds as steep.
        #expect(abs(falling / rising - 4.0 / 6.0) < 1e-9)
    }

    /// Two consecutive inhales, and the second is a sip rather than half the
    /// climb. Splitting the run by time is what draws it as the short top-up it
    /// is — the thing the technique is named for.
    @Test("The sigh's second inhale is a short top-up, not half the climb")
    func physiologicalSigh() {
        let rhythm = BreathRhythm(stage: SeededCatalogue.technique("physiological-sigh").stages[0])
        let first = rhythm.segments[0]
        let sip = rhythm.segments[1]

        #expect(first.kind == .inhale)
        #expect(sip.kind == .inhale)
        #expect(sip.endLevel == 1)
        // 1.5 seconds then 0.7: the first breath does most of the climbing.
        #expect(abs(first.endLevel - 1.5 / 2.2) < 1e-9)
        #expect(first.endLevel > 0.5)
    }

    /// The one place the grammar bends. The alternation *is* the technique and
    /// no other channel carries it, so the axis becomes which side rather than
    /// how full — and the line has to stay continuous across the swap.
    @Test("Alternate nostril draws each breath on its own side of the midline")
    func alternateNostrilIsSigned() {
        let technique = SeededCatalogue.technique("alternate-nostril")
        let sides = PhaseHints.sides(for: technique)

        // In left, out right, in right, out left — signed per breath by the
        // nostril its inhale goes through, so a swap never lands mid-breath.
        // Stage-indexed, like the hints it comes from.
        #expect(sides?.count == 1)
        #expect(sides?[0] == [1, 1, -1, -1])

        let rhythm = BreathRhythm(stage: technique.stages[0], signs: sides?[0])
        #expect(rhythm.signed)
        #expect(rhythm.segments[0].endLevel > 0)
        #expect(rhythm.segments[2].endLevel < 0)

        // Continuous: every segment starts where the last one finished, so the
        // line crosses the midline rather than jumping over it.
        for (previous, next) in zip(rhythm.segments, rhythm.segments.dropFirst()) {
            #expect(abs(next.startLevel - previous.endLevel) < 1e-12)
        }
    }

    /// Without the sign, alternate nostril is 4:6:4:6 and extended exhale is
    /// 4:6 — the same picture over a fixed window. The sign is load-bearing, and
    /// a technique with no nostrils to alternate between must not acquire one.
    @Test("A technique with no sides to alternate stays one-sided")
    func unhintedTechniquesStayOneSided() {
        #expect(PhaseHints.sides(for: SeededCatalogue.technique("extended-exhale")) == nil)
        #expect(PhaseHints.sides(for: SeededCatalogue.technique("coherent-breathing")) == nil)

        let rhythm = BreathRhythm(stage: SeededCatalogue.technique("extended-exhale").stages[0])
        #expect(!rhythm.signed)
        #expect(rhythm.segments.allSatisfy { $0.startLevel >= 0 && $0.endLevel >= 0 })
    }

    /// The retention has no length the clock owns, so it must not draw one.
    @Test("An open-ended retention draws flat and dashed, and repeats once")
    func openEndedRetention() {
        let stage = SeededCatalogue.technique("wim-hof-rounds").stages[1]
        let rhythm = BreathRhythm(stage: stage)

        // Hoisted out of `#expect`: the formatter rewrites a trailing closure
        // here into a key path, which the macro cannot type-check.
        let dashed = rhythm.segments.allSatisfy(\.dashed)
        let flat = rhythm.segments.allSatisfy { $0.startLevel == $0.endLevel }

        #expect(rhythm.cycles == 1)
        #expect(dashed)
        #expect(flat)
    }

    // MARK: What it draws, and what it says

    /// The silhouette a technique draws, rounded to a thousandth so a
    /// floating-point wobble is never mistaken for a different picture.
    private func silhouette(of technique: Technique) -> String {
        TechniqueFigure.all(for: technique)
            .flatMap(points(of:))
            .map { "\(($0.x * 1000).rounded()),\(($0.y * 1000).rounded())" }
            .joined(separator: " ")
    }

    /// Nine techniques, eight silhouettes — and the one collision is the honest
    /// kind. Box and long box are the same ratios at different lengths, so one
    /// shape is what they *are*. The grammar this replaced collided five of them
    /// on nothing more than "neither of us holds", which is not the same claim.
    @Test("No two techniques share a silhouette, except the two that share ratios")
    func silhouettesAreDistinct() {
        var seen: [String: String] = [:]

        for technique in SeededCatalogue.techniques {
            let drawn = silhouette(of: technique)
            if let other = seen[drawn] {
                #expect(
                    Set([technique.slug, other]) == ["box-breathing", "long-box-breathing"],
                    "`\(technique.slug)` draws the same as `\(other)`"
                )
            }
            seen[drawn] = technique.slug
        }
    }

    /// The claim that matters on screen: whatever the silhouettes do, no two
    /// techniques are the same drawing once their labels are on them.
    @Test("Every seeded technique draws something no other technique draws")
    func everyTechniqueIsDistinct() {
        var seen: [String: String] = [:]

        for technique in SeededCatalogue.techniques {
            let labels = TechniqueFigure.all(for: technique)
                .flatMap(\.labels)
                .map(\.text)
                .joined(separator: " ")
            let drawn = "\(silhouette(of: technique)) \(labels)"

            #expect(
                seen[drawn] == nil,
                "`\(technique.slug)` draws the same as `\(seen[drawn] ?? "")`"
            )
            seen[drawn] = technique.slug
        }
    }

    /// Every figure has to fit the box it is handed, whatever the durations.
    @Test("Every seeded technique stays inside its frame")
    func everyFigureFitsItsFrame() {
        for technique in SeededCatalogue.techniques {
            for drawn in TechniqueFigure.all(for: technique) {
                for point in points(of: drawn) {
                    #expect(point.x >= -0.001 && point.x <= 1.001, "`\(technique.slug)`")
                    #expect(point.y >= -0.001 && point.y <= 1.001, "`\(technique.slug)`")
                }
            }
        }
    }

    /// The chart is hidden from VoiceOver and the row of phase capsules that
    /// used to carry these facts as text is gone, so this string is now the only
    /// thing a screen reader has. It is also the generated SVG's `aria-label`,
    /// which is what makes the page and the app describe a technique alike.
    @Test("The description names every phase, in order, with its length")
    func describesEveryPhase() {
        let description = figure("box-breathing").description

        #expect(description == """
        One cycle: Breathe in for 4 seconds, Hold, lungs full for 4 seconds, \
        Breathe out for 4 seconds, Hold, lungs empty for 4 seconds. Repeated 8 times.
        """)
    }

    /// Bellows breath is the one exercise whose phases last exactly a second,
    /// so it is the one that says "1 seconds" if the length is glued to a bare
    /// plural. Somebody using a screen reader hears every one of these.
    @Test("A one-second phase is spoken in the singular")
    func describesASingleSecond() {
        let description = figure("bellows-breath").description

        #expect(description.contains("for 1 second,"))
        #expect(!description.contains("1 seconds"))
    }

    /// A nostril hint is a fact the phase kind cannot carry, and somebody
    /// listening rather than looking needs it most.
    @Test("The description carries the nostril where there is one")
    func describesNostrils() {
        let description = figure("alternate-nostril").description

        #expect(description.contains("Breathe in, left nostril"))
        #expect(description.contains("Breathe out, right nostril"))
    }

    /// An open-ended hold has no number to state, and stating the seeded one
    /// would promise a length the session does not keep.
    @Test("The retention is described as the person's to end")
    func describesTheRetention() {
        let description = TechniqueFigure
            .all(for: SeededCatalogue.technique("wim-hof-rounds"))[1]
            .description

        #expect(description.contains("as long as you can"))
        #expect(!description.contains("60 seconds"))
    }
}
