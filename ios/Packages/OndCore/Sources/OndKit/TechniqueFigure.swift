import CoreGraphics
import Foundation

/// One stage of a technique as a drawing: what shape it is, what colour each
/// part of it takes, what the parts are labelled, and how to say it aloud.
///
/// **One rule picks the family: corners are where the breath stops.** A cycle
/// that holds has real corners and draws as a polygon — box breathing a square,
/// 4-7-8 a triangle. A cycle that never holds has nothing to corner on and draws
/// as a line whose slope carries the timing. The alternative was the grammar
/// this replaced, which drew every technique as a rounded square varying only in
/// corner radius: five of the nine seeded techniques never hold, so all five
/// came out an identical circle, and coherent breathing and bellows breath — 5½
/// breaths a minute and twenty fast ones — were the same picture.
///
/// Geometry only, and deliberately no SwiftUI. Four renderers stand on this: the
/// phone's chart and its list row, the watch's carousel glyph, and the generator
/// that redraws the marketing site's figures (`mise run generate:diagrams`). A
/// technique is the same shape in all four because the shape is decided once,
/// here, and each renderer only turns commands into its own kind of path.
///
/// Coordinates are a unit box with y downwards. A renderer fits `bounds` rather
/// than the unit box: a triangle inscribed in the unit circle leaves corners of
/// empty space, and fitting the box instead would shrink every figure to make
/// room for nothing.
public struct TechniqueFigure: Sendable, Equatable {
    /// What a stroke means, named for the moment of breath rather than a colour
    /// — the palette belongs to whichever renderer is drawing.
    public enum Ink: Sendable, Equatable, Hashable {
        /// The lungs filling.
        case inhale
        /// The lungs emptying.
        case exhale
        /// A breath held, in or out.
        case hold
        /// The reference line a one-sided figure sits on, or the midline a
        /// signed one is measured from. Drawn faint, and never the subject.
        case baseline
    }

    /// One pen instruction. Deliberately the smallest set that draws every
    /// figure in the catalogue — a quadratic for the polygons' rounded corners,
    /// a cubic for the S-curve of a breath, and a circle for the dot that marks
    /// where the breath starts.
    public enum Command: Sendable, Equatable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case circle(centre: CGPoint, radius: CGFloat)
    }

    /// Which of the two grammars a figure is drawn in.
    ///
    /// Stored rather than left to be inferred. Every renderer and every test
    /// needs to know, and the facts they would otherwise infer it from — a
    /// baseline stroke, a stroke count — are drawing details that happen to
    /// correlate today. One of them already went wrong: a wash was laid inside
    /// every hold-free technique because "three or more strokes" was standing in
    /// for "this is a closed figure".
    public enum Family: Sendable, Equatable {
        /// A closed polygon, with a corner at every phase boundary.
        case polygon
        /// An open line — lung fullness over time.
        case line
    }

    /// What a stroke is *for*, as opposed to what colour it takes.
    public enum Role: Sendable, Equatable {
        /// One phase of the breath: the thing being drawn.
        case phase
        /// The reference line a figure is measured against.
        case baseline
        /// The dot marking where the breath starts.
        case start
    }

    public struct Stroke: Sendable, Equatable {
        public let ink: Ink
        public let role: Role
        public let commands: [Command]
        /// Whether to draw this stroke dashed — an open-ended stage, whose
        /// durations describe a typical pass rather than a scheduled one.
        public let dashed: Bool

        public init(
            _ ink: Ink,
            _ role: Role = .phase,
            _ commands: [Command],
            dashed: Bool = false
        ) {
            self.ink = ink
            self.role = role
            self.commands = commands
            self.dashed = dashed
        }
    }

    /// A word on the figure — `in · 4`, or `L`. The site labels its figures this
    /// way and the app now does too, which is what let the colour key underneath
    /// the chart go: a reader who has to decode a legend is reading twice.
    public struct Label: Sendable, Equatable {
        public let text: String
        /// Where the label hangs, in the same unit box as the strokes.
        public let at: CGPoint
        /// Which way the label sits from `at`, so a renderer can push it clear
        /// of the line without knowing the geometry that produced it.
        public let away: CGVector

        public init(text: String, at: CGPoint, away: CGVector) {
            self.text = text
            self.at = at
            self.away = away
        }
    }

    /// The radius of the dot marking where the breath starts, in unit-box terms.
    ///
    /// A closed figure has no beginning to find and no direction to read; the
    /// colours only resolve it once you already know which way round it goes.
    /// This is the one mark that says where to put your finger.
    static let startRadius: CGFloat = 0.022

    public let family: Family
    public let strokes: [Stroke]
    public let labels: [Label]
    /// The closed outline, for the wash a renderer may lay inside a polygon.
    /// Empty for a line, which encloses nothing.
    public let fill: [Command]
    /// How many times this stage repeats in a session. A caption, not a shape.
    public let cycles: Int
    /// What a screen reader should say instead of describing a picture.
    public let description: String
    /// The ink extent of the drawing, control points included.
    ///
    /// Stored rather than computed: it is a pure function of `strokes`, which
    /// never change, and every renderer needs it once per stroke — so a
    /// computed property walked all twenty-three of bellows breath's strokes
    /// twenty-three times per pass on any call site that forgot to hoist it.
    ///
    /// Control points rather than the true curve extent: it over-estimates a
    /// cubic's reach by a little, which lands as margin rather than as a clipped
    /// wave.
    public let bounds: CGRect

    /// One figure per stage, in play order.
    ///
    /// Per stage rather than per technique because a staged protocol mixes
    /// families: a Wim Hof round is a rapid line, then an open-ended retention,
    /// then a three-phase recovery that is a triangle. One drawing spanning all
    /// three would have to pick a grammar and misrepresent two of them.
    public static func all(for technique: Technique) -> [Self] {
        let sides = PhaseHints.sides(for: technique)
        let hints = PhaseHints.hints(for: technique)

        return technique.stages.enumerated().map { index, stage in
            Self(
                stage: stage,
                sides: sides?.indices.contains(index) == true ? sides?[index] : nil,
                hints: hints?.indices.contains(index) == true ? hints?[index] : nil,
                // A staged protocol draws one figure per stage side by side, and
                // three sets of labels at a third of the width is a smudge. The
                // stage titles beside the chart carry what they would have said.
                labelled: technique.stages.count == 1
            )
        }
    }

    /// - Parameters:
    ///   - sides: `+1`/`-1` per phase of a cycle where the technique alternates
    ///     sides, from `PhaseHints.sides(for:)`. Nil draws one-sided.
    ///   - hints: the per-phase nostril hints, for the `L`/`R` marks.
    ///   - labelled: whether to write the phase durations onto the figure. A
    ///     staged technique draws three small figures side by side, and three
    ///     sets of labels at that size is a smudge.
    public init(
        stage: Stage,
        sides: [Double]? = nil,
        hints: [String?]? = nil,
        labelled: Bool = true
    ) {
        cycles = stage.cycles
        description = Self.describe(stage: stage, hints: hints)

        if BreathPolygon.suits(stage) {
            let polygon = BreathPolygon(stage: stage)
            family = .polygon
            strokes = Self.strokes(of: polygon)
            labels = labelled ? Self.labels(of: polygon, phases: stage.phases) : []
            fill = polygon.outline
        } else {
            let rhythm = BreathRhythm(stage: stage, signs: sides)
            family = .line
            strokes = Self.strokes(of: rhythm)
            labels = labelled ? Self.labels(of: rhythm, stage: stage, hints: hints) : []
            // A line encloses nothing, so there is nothing to wash. Taken from
            // the branch that knows the family rather than inferred later from
            // a stroke count — which is what let every hold-free technique pick
            // up a gradient across a path it never draws.
            fill = []
        }

        bounds = Self.extent(of: strokes)
    }

    /// The strokes a renderer should actually draw, merged into one per pen.
    ///
    /// Every command list starts with a `move`, so runs that share a pen
    /// concatenate into one path with no visual change. That matters because a
    /// renderer makes one view per stroke: bellows breath's eleven cycles are
    /// twenty-three strokes, and drawing them merged is three views instead of
    /// twenty-three — inside a 38-point list row, twenty-three times over.
    ///
    /// Ordered by first appearance so the baseline still lands under the line
    /// and the start dot still lands on top of it.
    public var drawable: [Stroke] {
        var order: [Stroke] = []

        for stroke in strokes {
            let match = order.firstIndex {
                $0.ink == stroke.ink && $0.role == stroke.role && $0.dashed == stroke.dashed
            }

            if let match {
                order[match] = Stroke(
                    stroke.ink,
                    stroke.role,
                    order[match].commands + stroke.commands,
                    dashed: stroke.dashed
                )
            } else {
                order.append(stroke)
            }
        }

        return order
    }

    /// How to place this figure in a rect: uniform, centred, fitted to the ink.
    ///
    /// Here rather than in each renderer, and this is the piece that matters
    /// most. "The page and the app draw a technique the same way" is what the
    /// whole arrangement exists to guarantee, and placing the figure is the last
    /// step of drawing one — so a second copy of this rule is the one divergence
    /// `mise run check:diagrams` could never catch. It regenerates the site's
    /// SVG from whatever rule the generator holds, so two rules that disagree
    /// produce no diff at all and simply render at different scales.
    ///
    /// Uniform because stretching would oval the start dot and turn box
    /// breathing's square into a rectangle — the one thing that drawing exists
    /// to say. Fitted to `bounds` rather than the unit box because a triangle
    /// inscribed in the unit circle leaves two corners of empty space, and
    /// fitting the box would shrink every figure to make room for nothing.
    ///
    /// - Parameter inset: room for the stroke's own width, which straddles the
    ///   path.
    public func transform(into rect: CGRect, inset: CGFloat = 0) -> CGAffineTransform {
        Self.transform(fitting: bounds, into: rect, inset: inset)
    }

    /// The same rule against an extent the caller already holds — a renderer
    /// that draws one stroke at a time has the figure's `bounds` but not the
    /// figure.
    public static func transform(
        fitting bounds: CGRect,
        into rect: CGRect,
        inset: CGFloat = 0
    ) -> CGAffineTransform {
        let available = rect.insetBy(dx: inset, dy: inset)
        guard bounds.width > 0, bounds.height > 0, available.width > 0, available.height > 0 else {
            return .identity
        }

        let scale = min(available.width / bounds.width, available.height / bounds.height)
        return CGAffineTransform(
            translationX: rect.midX - bounds.midX * scale,
            y: rect.midY - bounds.midY * scale
        )
        .scaledBy(x: scale, y: scale)
    }

    /// The extent of a set of strokes, control points included.
    private static func extent(of strokes: [Stroke]) -> CGRect {
        var minimum = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: .greatestFiniteMagnitude)
        var maximum = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)

        func include(_ point: CGPoint) {
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
        }

        for stroke in strokes {
            for command in stroke.commands {
                switch command {
                case let .move(point), let .line(point):
                    include(point)
                case let .quadCurve(point, control):
                    include(point)
                    include(control)
                case let .curve(point, control1, control2):
                    include(point)
                    include(control1)
                    include(control2)
                case let .circle(centre, radius):
                    include(CGPoint(x: centre.x - radius, y: centre.y - radius))
                    include(CGPoint(x: centre.x + radius, y: centre.y + radius))
                }
            }
        }

        guard minimum.x <= maximum.x else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: minimum.x,
            y: minimum.y,
            width: maximum.x - minimum.x,
            height: maximum.y - minimum.y
        )
    }
}

public extension [TechniqueFigure] {
    /// A whole technique's figures as one sentence.
    ///
    /// The app hands this to VoiceOver and the generator writes it into the
    /// SVG's `aria-label`, so a technique is described identically wherever it
    /// is met. Here rather than joined at each call site, because "the same
    /// sentence" was previously a claim two doc comments made about each other.
    ///
    /// Deliberately **not** named `description`: that would shadow `Array`'s own
    /// `CustomStringConvertible` conformance, so string interpolation and every
    /// generic path would keep yielding the struct dump while these two call
    /// sites quietly got something else.
    var spoken: String {
        map(\.description).joined(separator: " ")
    }
}
