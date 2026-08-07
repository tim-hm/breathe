import BreatheKit
import CoreGraphics
import Foundation
import Testing

/// The mapping from a technique to its picture.
///
/// Worth pinning because the coordinates are a port: the marketing site is the
/// reference, and the failure mode is silent — a slug that stops matching drops
/// to the derived drawing and the app simply shows a different picture from the
/// page somebody arrived from, with nothing to say it happened.
@Suite("Technique drawings")
struct TechniqueDrawingTests {
    private func technique(
        slug: String,
        phases: [Phase] = [
            Phase(kind: .inhale, duration: .seconds(4)),
            Phase(kind: .exhale, duration: .seconds(6)),
        ]
    ) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: .calm,
            stages: [Stage(phases: phases, cycles: 1)],
            recommendedRounds: 1
        )
    }

    /// The five the site draws, plus the long-count box, which takes the square
    /// because it *is* a box — deriving a trapezoid for it would put two
    /// members of one family in two different grammars.
    @Test("Every technique the site draws is ported, and nothing else claims to be")
    func portsTheSiteFigures() {
        let ported = [
            "box-breathing",
            "long-box-breathing",
            "coherent-breathing",
            "four-seven-eight",
            "physiological-sigh",
            "bellows-breath",
        ]
        let derived = ["extended-exhale", "wim-hof-rounds", "alternate-nostril", "brand-new-slug"]

        #expect(ported.allSatisfy(TechniqueDrawing.isPorted(slug:)))
        #expect(derived.allSatisfy { !TechniqueDrawing.isPorted(slug: $0) })
    }

    /// Coherent is the one Tim checked against the page: it has to oscillate
    /// about a midline rather than rise from empty, which means its line both
    /// starts and ends at the same height, and reaches above and below it.
    @Test("Coherent breathing oscillates about its midline")
    func drawsCoherentAsASine() throws {
        let drawing = TechniqueDrawing(technique: technique(slug: "coherent-breathing"))
        let line = try #require(drawing.strokes.first { $0.commands.count > 2 })

        var heights: [CGFloat] = []
        for command in line.commands {
            switch command {
            case let .move(point), let .line(point): heights.append(point.y)
            case let .curve(point, _, _): heights.append(point.y)
            default: break
            }
        }

        #expect(heights.allSatisfy { $0 == 95 }, "every node sits on the midline")
        #expect(line.commands.count == 5, "one move and four half-waves")
    }

    /// Box is the case a waveform cannot express at all.
    @Test("Box breathing is a square, with no baseline under it")
    func drawsBoxAsASquare() {
        let drawing = TechniqueDrawing(technique: technique(slug: "box-breathing"))

        let isSquare = drawing.strokes.contains { stroke in
            stroke.commands.contains { command in
                if case let .roundedRect(rect, _) = command {
                    return rect.width == rect.height
                }
                return false
            }
        }

        #expect(isSquare)
        #expect(drawing.strokes.allSatisfy { $0.ink == .accent }, "the square carries no baseline")
    }

    /// The derived drawings have to look like the ported ones or the catalogue
    /// stops reading as one hand: a faint baseline, an accent line, a start dot.
    @Test("A technique the site never drew still gets the family's grammar")
    func derivesInTheSameGrammar() {
        let drawing = TechniqueDrawing(technique: technique(slug: "extended-exhale"))

        #expect(drawing.strokes.count == 3)
        #expect(drawing.strokes.first?.ink == .faint, "the baseline is drawn first, underneath")
        #expect(
            drawing.strokes.last?.commands.contains { command in
                if case .circle = command {
                    return true
                }
                return false
            } == true,
            "and the start dot last, on top"
        )
    }

    /// A renderer fits the ink, not the site's label margins, so the bounds have
    /// to describe the drawing rather than the viewBox.
    @Test("Bounds cover the drawing and not the empty margins")
    func boundsDescribeTheInk() {
        let bounds = TechniqueDrawing(technique: technique(slug: "coherent-breathing")).bounds

        #expect(bounds.minX == 16.5, "the start dot's left edge, not the viewBox's")
        #expect(bounds.maxX == 200)
        #expect(bounds.width < TechniqueDrawing.design.width)
        #expect(bounds.height < TechniqueDrawing.design.height)
    }
}
