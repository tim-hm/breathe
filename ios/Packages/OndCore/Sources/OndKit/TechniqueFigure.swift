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
    /// Named rather than left to be inferred. The renderers do not branch on it
    /// — they draw whatever `fill` and `drawable` hand them, which is the point
    /// — but the construction below does, and the tests assert on it, so the
    /// grammar a figure belongs to should be something the type says rather than
    /// something a reader reconstructs from a stroke count or an empty `fill`.
    /// Those are drawing details that happen to correlate, and one of them
    /// already went wrong: a wash was laid inside every hold-free technique
    /// because "three or more strokes" was standing in for "this is a closed
    /// figure".
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

        /// How heavily to draw this stroke, relative to a figure's line width.
        ///
        /// A baseline is reference rather than subject, so it is drawn at a
        /// hairline whatever weight the figure carries.
        ///
        /// Here rather than in `OndStyle` because the SVG generator cannot see
        /// that module and was left spelling the rule out a fourth time — and a
        /// renderer holding its own copy of the rule is the one divergence
        /// `mise run check:diagrams` structurally cannot catch, since both sides
        /// regenerate from whatever each happens to believe.
        public func weight(on lineWidth: CGFloat) -> CGFloat {
            role == .baseline ? 1 : lineWidth
        }

        /// The dash a person-timed phase draws in — on for four, off for five,
        /// in the same units as the line width. Shared with the site for the
        /// reason above: an open-ended retention that dashed differently in the
        /// two places would look like two different exercises.
        public static let dash: [CGFloat] = [4, 5]
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
    /// The strokes a renderer should actually draw, merged into one per pen.
    ///
    /// Every command list starts with a `move`, so runs that share a pen
    /// concatenate into one path with no visual change. That matters because a
    /// renderer makes one view per stroke: bellows breath's eleven cycles are
    /// twenty-three strokes, and drawing them merged is three views instead of
    /// twenty-three — inside a 38-point list row, twenty-three times over.
    ///
    /// Stored for the same reason `bounds` is, and it is the stronger case of
    /// the two: the merge concatenates arrays as it folds, so recomputing it
    /// re-copied every command on every layout pass, at all four call sites.
    ///
    /// Ordered by first appearance so the baseline still lands under the line
    /// and the start dot still lands on top of it.
    public let drawable: [Stroke]

    /// One figure per stage, in play order.
    ///
    /// Per stage rather than per technique because a staged protocol mixes
    /// families: a Wim Hof round is a rapid line, then an open-ended retention,
    /// then a three-phase recovery that is a triangle. One drawing spanning all
    /// three would have to pick a grammar and misrepresent two of them.
    public static func all(for technique: Technique) -> [Self] {
        // Both tables are stage-indexed and shape-checked against this very
        // technique, so a plain subscript is in bounds by construction — the
        // check is the guard.
        let hints = PhaseHints.hints(for: technique)
        let sides = PhaseHints.sides(for: technique, hints: hints)

        return technique.stages.enumerated().map { index, stage in
            Self(
                stage: stage,
                sides: sides?[index],
                hints: hints?[index],
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
        drawable = Self.merge(strokes)
    }

    /// Merges `strokes` into one per pen, for the renderers.
    private static func merge(_ strokes: [Stroke]) -> [Stroke] {
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
    /// - Parameter lineWidth: the weight the figure will be stroked at. The rect
    ///   is inset by half of it, which is exactly what a stroke straddling the
    ///   path needs — asked for as the width rather than as the inset because
    ///   the four renderers had four answers to the same question, from the full
    ///   width down to nothing at all.
    public func transform(into rect: CGRect, lineWidth: CGFloat = 0) -> CGAffineTransform {
        Self.transform(fitting: bounds, into: rect, lineWidth: lineWidth)
    }

    /// The same rule against an extent the caller already holds — a renderer
    /// that draws one stroke at a time has the figure's `bounds` but not the
    /// figure.
    public static func transform(
        fitting bounds: CGRect,
        into rect: CGRect,
        lineWidth: CGFloat = 0
    ) -> CGAffineTransform {
        let inset = lineWidth / 2
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
