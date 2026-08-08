import CoreGraphics
import Foundation

/// Turning each family's geometry into the strokes and labels a renderer draws.
///
/// Split from `TechniqueFigure` itself, which holds what a figure *is* — the
/// command vocabulary, the family choice, the extent every renderer fits. This
/// file holds how each family becomes one: the polygon's corner-splitting, the
/// line's S-curves and label placement, and the words that go on both.
///
/// Internal rather than private only because the initialiser that calls these
/// sits in the other file. Nothing outside `TechniqueFigure` should reach for
/// them: a caller wanting strokes wants a figure.
extension TechniqueFigure {
    static func ink(_ kind: PhaseKind) -> Ink {
        switch kind {
        case .inhale: .inhale
        case .exhale: .exhale
        case .holdIn, .holdOut: .hold
        }
    }

    // MARK: The polygon

    static func strokes(of polygon: BreathPolygon) -> [Stroke] {
        // Each phase runs from the middle of the corner it leaves, along its
        // straight side, to the middle of the corner it enters — so the two
        // phases meeting at a vertex own half the turn each and neither colour
        // bleeds across it. `Side.commands` is that run, shared with the outline
        // the wash fills.
        var strokes = polygon.sides.map { side in
            Stroke(ink(side.kind), .phase, side.commands, dashed: side.dashed)
        }

        strokes.append(
            Stroke(.inhale, .start, [.circle(centre: polygon.start, radius: startRadius)])
        )
        return strokes
    }

    static func labels(of polygon: BreathPolygon, phases: [Phase]) -> [Label] {
        let centre = CGPoint(x: 0.5, y: 0.5)

        return zip(polygon.sides, phases).map { side, phase in
            let midpoint = side.midpoint
            let reach = max(hypot(midpoint.x - centre.x, midpoint.y - centre.y), 0.001)

            return Label(
                text: word(phase.kind, lasting: [phase.duration], dashed: side.dashed),
                at: midpoint,
                // Outward from the middle of the figure, which for a convex
                // polygon is away from every side it could collide with.
                away: CGVector(
                    dx: (midpoint.x - centre.x) / reach,
                    dy: (midpoint.y - centre.y) / reach
                )
            )
        }
    }

    // MARK: The line

    static func strokes(of rhythm: BreathRhythm) -> [Stroke] {
        // The midline for a signed figure, the empty-lung baseline for a
        // one-sided one. Either way it is the level the breath starts from, so
        // it is the same line in both.
        let ground = place(0, in: rhythm)
        var strokes = [Stroke(.baseline, .baseline, [
            .move(to: CGPoint(x: 0, y: ground)),
            .line(to: CGPoint(x: 1, y: ground)),
        ])]

        for segment in rhythm.segments {
            let from = CGPoint(x: segment.start, y: place(segment.startLevel, in: rhythm))
            let to = CGPoint(x: segment.end, y: place(segment.endLevel, in: rhythm))

            let commands: [Command] = switch segment.kind {
            case .inhale, .exhale:
                // An S-curve, like the session orb's smoothstepped scale: a
                // breath does not change pace at its boundaries.
                [.move(to: from), .curve(
                    to: to,
                    control1: CGPoint(x: (from.x + to.x) / 2, y: from.y),
                    control2: CGPoint(x: (from.x + to.x) / 2, y: to.y)
                )]
            case .holdIn, .holdOut:
                [.move(to: from), .line(to: to)]
            }

            strokes.append(Stroke(ink(segment.kind), .phase, commands, dashed: segment.dashed))
        }

        if let first = rhythm.segments.first {
            strokes.append(Stroke(.inhale, .start, [.circle(
                centre: CGPoint(x: first.start, y: place(first.startLevel, in: rhythm)),
                radius: startRadius
            )]))
        }

        return strokes
    }

    /// A level onto the unit box's y, which runs downwards. A signed figure
    /// spends half its height either side of the midline; a one-sided one climbs
    /// from the bottom.
    static func place(_ level: Double, in rhythm: BreathRhythm) -> CGFloat {
        rhythm.signed ? CGFloat(0.5 - level / 2) : CGFloat(1 - level)
    }

    /// The narrowest a cycle can be and still carry a word per phase.
    ///
    /// Below about a quarter of the figure the labels are wider than the cycle
    /// they name, so they collide with each other rather than pointing at
    /// anything. Bellows breath fits eleven cycles in the window and is the case
    /// this exists for.
    static let labellableCycle = 0.26

    static func labels(of rhythm: BreathRhythm, stage: Stage, hints: [String?]?) -> [Label] {
        // The first cycle only. The rest are the same words at the same heights,
        // and eleven bellows cycles labelled eleven times is texture rather than
        // information.
        let runs = runs(of: rhythm.segments.filter { $0.cycle == 0 })
        let words = runs.map { run in
            word(for: run, of: stage, hints: hints)
        }

        // Too fast to label run by run: one caption under the whole figure,
        // which is what the marketing site's hand-drawn bellows figure did for
        // the same reason.
        guard Double(rhythm.cycles) <= 1 / labellableCycle else {
            return [Label(
                text: words.joined(separator: ", "),
                at: CGPoint(x: 0.5, y: place(rhythm.signed ? -1 : 0, in: rhythm)),
                away: CGVector(dx: 0, dy: 1)
            )]
        }

        // Anchored at the top or bottom of the band rather than on the line
        // itself: a label pinned to the middle of a rising curve sits on top of
        // it, and the margin above and below is empty by construction.
        let top = place(1, in: rhythm)
        let bottom = place(rhythm.signed ? -1 : 0, in: rhythm)

        // A signed figure is one lobe per breath, so it gets one label per lobe.
        // Labelling each half separately puts two words in the width of one and
        // they overlap — and a breath's two halves belong together anyway, which
        // is the whole reason the sign follows the breath rather than the phase.
        guard !rhythm.signed else {
            let lobes = Dictionary(grouping: zip(runs, words), by: { run, _ in
                run.contains { $0.startLevel < 0 || $0.endLevel < 0 }
            })

            return lobes.map { below, pairs in
                let starts = pairs.map { $0.0[0].start }
                let ends = pairs.map { $0.0[$0.0.count - 1].end }

                return Label(
                    text: pairs.map(\.1).joined(separator: ", "),
                    at: CGPoint(
                        x: ((starts.min() ?? 0) + (ends.max() ?? 1)) / 2,
                        y: below ? bottom : top
                    ),
                    away: CGVector(dx: 0, dy: below ? 1 : -1)
                )
            }
            // Dictionary order is not stable, and a figure whose labels swap
            // places between two runs of the generator is a diff every time.
            .sorted { $0.at.y < $1.at.y }
        }

        return zip(runs, words).map { run, text in
            // The rise and the hold go above the line and the fall below, which
            // is both true to the shape and what spreads the labels apart.
            let below = run[0].kind == .exhale

            return Label(
                text: text,
                at: CGPoint(
                    x: (run[0].start + run[run.count - 1].end) / 2,
                    y: below ? bottom : top
                ),
                away: CGVector(dx: 0, dy: below ? 1 : -1)
            )
        }
    }

    /// Consecutive segments of the same kind, grouped.
    ///
    /// The physiological sigh's two inhales are one gesture — a breath and a sip
    /// on top of it — and labelling them separately puts two words in the space
    /// of one, overlapping. Grouping also states the thing the exercise is named
    /// for: `in · 1.5 + 0.7` reads as a double inhale, where two labels read as
    /// two breaths.
    static func runs(of segments: [BreathRhythm.Segment]) -> [[BreathRhythm.Segment]] {
        segments.reduce(into: [[BreathRhythm.Segment]]()) { runs, segment in
            if var last = runs.last, last[0].kind == segment.kind {
                last.append(segment)
                runs[runs.count - 1] = last
            } else {
                runs.append([segment])
            }
        }
    }

    /// `in · 1.5 + 0.7`, or `in · 4 L` where a nostril is named.
    static func word(
        for run: [BreathRhythm.Segment],
        of stage: Stage,
        hints: [String?]?
    ) -> String {
        let phases = run.compactMap { stage.phases[safe: $0.phase] }
        guard let first = phases.first else { return "" }

        let hint = PhaseHints.hint(hints, at: run[0].phase)

        return word(
            first.kind,
            lasting: phases.map(\.duration),
            dashed: run[0].dashed,
            nostril: hint.map { String($0.prefix(1)) }
        )
    }

    // MARK: Words

    /// `in · 4`, in the marketing site's own idiom. The separator is the site's
    /// middle dot rather than a colon, and the unit is left off because every
    /// number on a figure is seconds.
    ///
    /// An open-ended phase gets the word alone: its seeded duration describes a
    /// typical hold, and printing it would promise a length the session does not
    /// keep.
    ///
    /// - Parameters:
    ///   - lasting: one duration per phase in the run. The sigh's two inhales
    ///     join with a `+`, which reads as the double breath it is.
    ///   - nostril: `L` or `R`, riding on a space rather than another middle dot
    ///     — `in · 4 L` reads as one item where `in · 4 · L` reads as three.
    static func word(
        _ kind: PhaseKind,
        lasting: [Duration],
        dashed: Bool,
        nostril: String? = nil
    ) -> String {
        guard !dashed else { return name(of: kind) }

        let word = "\(name(of: kind)) · \(lasting.map(\.inSeconds).joined(separator: " + "))"
        return nostril.map { "\(word) \($0)" } ?? word
    }

    static func name(of kind: PhaseKind) -> String {
        switch kind {
        case .inhale: "in"
        case .exhale: "out"
        case .holdIn, .holdOut: "hold"
        }
    }

    /// What a screen reader says instead of the picture.
    ///
    /// This is not decoration: the phone's chart is hidden from VoiceOver, and
    /// the row of phase capsules that used to carry these facts as text is gone
    /// now the figure carries its own labels. The same string becomes the
    /// generated SVG's `aria-label`, so the page and the app describe a
    /// technique identically.
    ///
    /// - Parameter drawn: how many cycles the figure puts on the page. Passed
    ///   in rather than read off the stage, because reading it off the stage is
    ///   the bug this parameter exists to make impossible: `stage.cycles` is how
    ///   often the exercise repeats, not how much of it the drawing shows, and
    ///   announcing the first over a picture of the second told a screen-reader
    ///   user about twenty-seven coherent breathing cycles beside a figure that
    ///   draws two.
    static func describe(stage: Stage, hints: [String?]?, drawn: Int) -> String {
        let phases = stage.phases.enumerated().map { index, phase -> String in
            let instruction = PhaseHints.spoken(phase.kind, hint: PhaseHints.hint(hints, at: index))

            guard !stage.openEnded else { return "\(instruction), for as long as you can" }
            // Spelled out as a measurement rather than a number and a bare
            // "seconds", so a one-second bellows breath is not announced as
            // "for 1 seconds".
            return "\(instruction) for \(phase.duration.spokenLength)"
        }

        let cycle = phases.joined(separator: ", ")
        guard stage.cycles > 1 else { return "One cycle: \(cycle)." }

        // Named only where the drawing falls short of the exercise. A line that
        // fits every cycle of its stage — the physiological sigh's three — has
        // already shown what the clause before it claims, and saying so twice is
        // noise in a sentence somebody is listening to rather than skimming.
        let shortfall = drawn < stage.cycles ? ", of which this figure draws \(drawn)" : ""
        return "One cycle: \(cycle). Repeated \(stage.cycles) times\(shortfall)."
    }
}
