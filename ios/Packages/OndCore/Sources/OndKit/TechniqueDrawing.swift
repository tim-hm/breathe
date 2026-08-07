import CoreGraphics
import Foundation

/// A technique's identity as a line drawing, in normalised design-box
/// coordinates.
///
/// These are ports of the hand-authored SVGs on the marketing site
/// (`web/index.html`), coordinate for coordinate, because the site is the
/// reference: somebody who arrives from the page and opens the app should
/// recognise the same picture. That is also why this is a table of drawings
/// rather than one curve generator — the site deliberately does not use a single
/// grammar. Coherent breathing is a sine oscillating about a midline, 4-7-8 is a
/// bottom-based rise-hold-descend timeline, the physiological sigh is two quick
/// rises and one long fall, bellows is a rapid zigzag, and box breathing is not a
/// waveform at all but a square. Each drawing *is* that technique's identity, and
/// a generic fullness curve cannot express any of them.
///
/// Geometry only, and deliberately no SwiftUI: both the phone and the watch draw
/// these, so the coordinates live here and each target keeps its own small
/// renderer. That is the same split `GoalAccent` documents — shared meaning,
/// per-target drawing.
public struct TechniqueDrawing: Sendable, Equatable {
    /// Which of the two pens a stroke is drawn with. Named for its role rather
    /// than a colour, because the palette is the app's business: `accent` is the
    /// technique's goal colour and `faint` is the baseline the site draws at 40%
    /// ink under four of the five figures.
    public enum Ink: Sendable, Equatable {
        case accent
        case faint
    }

    /// One pen instruction. The set is exactly what the site's five figures use
    /// and no more — a rounded rect because box breathing is drawn as one, and a
    /// circle because every figure marks where the breath starts.
    public enum Command: Sendable, Equatable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case circle(centre: CGPoint, radius: CGFloat)
        case roundedRect(CGRect, radius: CGFloat)
    }

    public struct Stroke: Sendable, Equatable {
        public let ink: Ink
        public let commands: [Command]

        public init(_ ink: Ink, _ commands: [Command]) {
            self.ink = ink
            self.commands = commands
        }
    }

    /// In play order: the baseline first where there is one, then the line, then
    /// the dot that marks where the breath starts.
    public let strokes: [Stroke]

    public init(strokes: [Stroke]) {
        self.strokes = strokes
    }

    /// The drawing for a technique — the site's where it drew one, and one
    /// derived from the technique's own rhythm where it did not.
    ///
    /// Keyed on the slug, which the catalogue promises to keep stable, so a
    /// technique the server renames keeps its picture and a technique the server
    /// adds gets a derived one rather than none.
    public init(technique: Technique) {
        self = Self.ported(for: technique.slug) ?? Self(rhythm: BreathRhythm(technique: technique))
    }

    /// Whether this technique's picture is the site's own drawing rather than
    /// one derived from its rhythm. Exposed so a test can pin the mapping.
    public static func isPorted(slug: String) -> Bool {
        ported(for: slug) != nil
    }

    private static func ported(for slug: String) -> Self? {
        switch slug {
        case "box-breathing", "long-box-breathing": box
        case "coherent-breathing": coherent
        case "four-seven-eight": fourSevenEight
        case "physiological-sigh": physiologicalSigh
        case "bellows-breath": bellows
        default: nil
        }
    }

    /// The box the coordinates below are authored in — the site's `viewBox`,
    /// y downwards. Nothing renders at this size; it is the frame the numbers
    /// mean something in.
    public static let design = CGSize(width: 220, height: 170)

    /// The ink extent of the drawing, control points included.
    ///
    /// A renderer fits *this* rather than `design`, because the site's figures
    /// leave wide margins for their text labels — and the app draws no labels, so
    /// fitting the whole viewBox would shrink every picture to fit whitespace
    /// that is not there. Control points rather than the true curve extent: it
    /// over-estimates a cubic's reach by a little, which lands as margin rather
    /// than as a clipped wave.
    public var bounds: CGRect {
        var minimum = CGPoint(
            x: CGFloat.greatestFiniteMagnitude,
            y: CGFloat.greatestFiniteMagnitude
        )
        var maximum = CGPoint(
            x: -CGFloat.greatestFiniteMagnitude,
            y: -CGFloat.greatestFiniteMagnitude
        )

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
                case let .curve(point, control1, control2):
                    include(point)
                    include(control1)
                    include(control2)
                case let .circle(centre, radius):
                    include(CGPoint(x: centre.x - radius, y: centre.y - radius))
                    include(CGPoint(x: centre.x + radius, y: centre.y + radius))
                case let .roundedRect(rect, _):
                    include(rect.origin)
                    include(CGPoint(x: rect.maxX, y: rect.maxY))
                }
            }
        }

        guard minimum.x <= maximum.x else { return CGRect(origin: .zero, size: Self.design) }
        return CGRect(
            x: minimum.x,
            y: minimum.y,
            width: maximum.x - minimum.x,
            height: maximum.y - minimum.y
        )
    }
}

/// The site's figures, ported.
///
/// Every number below is lifted from `web/index.html`. Resist the urge to tidy
/// them: they were placed by eye against the copy beside them, and a rounded
/// coordinate is a drawing that no longer matches the page it came from.
private extension TechniqueDrawing {
    /// Where a figure's start dot sits, and the radius the site draws it at.
    static let dotRadius: CGFloat = 3.5

    /// Four equal sides. Not a waveform at all — the square *is* the technique,
    /// which is the clearest case for why these are ported rather than computed.
    ///
    /// Authored in the site's 200-wide viewBox and shifted ten to the right, so
    /// it sits in the same 220-wide box as the other four.
    static var box: Self {
        Self(strokes: [
            Stroke(
                .accent,
                [.roundedRect(CGRect(x: 55, y: 30, width: 110, height: 110), radius: 10)]
            ),
            Stroke(.accent, [.circle(centre: CGPoint(x: 55, y: 140), radius: dotRadius)]),
        ])
    }

    /// A four-second rise, a seven-second flat hold, then a slow eight-second
    /// descent.
    static var fourSevenEight: Self {
        Self(strokes: [
            baseline(y: 130),
            Stroke(.accent, [
                .move(to: CGPoint(x: 20, y: 130)),
                .line(to: CGPoint(x: 56, y: 55)),
                .line(to: CGPoint(x: 119, y: 55)),
                .curve(
                    to: CGPoint(x: 191, y: 130),
                    control1: CGPoint(x: 150, y: 55),
                    control2: CGPoint(x: 175, y: 105)
                ),
            ]),
            dot(x: 20, y: 130),
        ])
    }

    /// Two quick rises for the double inhale, then one long slow descent.
    static var physiologicalSigh: Self {
        Self(strokes: [
            baseline(y: 140),
            Stroke(.accent, [
                .move(to: CGPoint(x: 20, y: 140)),
                .line(to: CGPoint(x: 52, y: 78)),
                .line(to: CGPoint(x: 60, y: 88)),
                .line(to: CGPoint(x: 76, y: 52)),
                .curve(
                    to: CGPoint(x: 196, y: 140),
                    control1: CGPoint(x: 110, y: 66),
                    control2: CGPoint(x: 160, y: 116)
                ),
            ]),
            dot(x: 20, y: 140),
        ])
    }

    /// A rapid even zigzag: quick one-second breaths in and out.
    static var bellows: Self {
        var commands: [Command] = [.move(to: CGPoint(x: 20, y: 120))]
        // Thirteen alternating points on a fourteen-pixel step, exactly as the
        // site spells them out.
        for step in 1 ... 12 {
            commands.append(
                .line(to: CGPoint(x: 20 + 14 * CGFloat(step), y: step.isMultiple(of: 2) ? 120 : 70))
            )
        }

        return Self(strokes: [baseline(y: 120), Stroke(.accent, commands), dot(x: 20, y: 120)])
    }

    /// A smooth even wave about a midline — the one figure that oscillates
    /// rather than starting from empty, and the one Tim checked first.
    static var coherent: Self {
        Self(strokes: [
            baseline(y: 95),
            Stroke(.accent, [
                .move(to: CGPoint(x: 20, y: 95)),
                .curve(
                    to: CGPoint(x: 65, y: 95),
                    control1: CGPoint(x: 32, y: 52),
                    control2: CGPoint(x: 52, y: 52)
                ),
                .curve(
                    to: CGPoint(x: 110, y: 95),
                    control1: CGPoint(x: 78, y: 138),
                    control2: CGPoint(x: 98, y: 138)
                ),
                .curve(
                    to: CGPoint(x: 155, y: 95),
                    control1: CGPoint(x: 122, y: 52),
                    control2: CGPoint(x: 142, y: 52)
                ),
                .curve(
                    to: CGPoint(x: 200, y: 95),
                    control1: CGPoint(x: 168, y: 138),
                    control2: CGPoint(x: 188, y: 138)
                ),
            ]),
            dot(x: 20, y: 95),
        ])
    }

    static func baseline(y: CGFloat) -> Stroke {
        Stroke(.faint, [.move(to: CGPoint(x: 20, y: y)), .line(to: CGPoint(x: 200, y: y))])
    }

    static func dot(x: CGFloat, y: CGFloat) -> Stroke {
        Stroke(.accent, [.circle(centre: CGPoint(x: x, y: y), radius: dotRadius)])
    }
}

/// The derived drawing, for a technique the site never drew.
///
/// Same grammar as the site's bottom-based figures — a faint baseline, one
/// accent line from empty lungs, a dot where it starts — so a catalogue the
/// server has grown still reads as one family rather than as five drawings and a
/// stranger. The shape comes from `BreathRhythm`, which already owns every
/// judgement about what a technique's line shows.
private extension TechniqueDrawing {
    /// The band the derived line is drawn in: empty lungs on the site's baseline
    /// for this family, full lungs level with the tops of the ported figures.
    static let derivedBaseline: CGFloat = 140
    static let derivedTop: CGFloat = 52
    static let derivedLeft: CGFloat = 20
    static let derivedRight: CGFloat = 200

    init(rhythm: BreathRhythm) {
        func place(_ x: Double, _ level: Double) -> CGPoint {
            CGPoint(
                x: Self.derivedLeft + CGFloat(x) * (Self.derivedRight - Self.derivedLeft),
                y: Self.derivedBaseline
                    - CGFloat(level) * (Self.derivedBaseline - Self.derivedTop)
            )
        }

        guard let first = rhythm.segments.first else {
            self.init(strokes: [Self.baseline(y: Self.derivedBaseline)])
            return
        }

        let start = place(first.start, first.startLevel)
        var commands: [Command] = [.move(to: start)]

        for segment in rhythm.segments {
            let from = place(segment.start, segment.startLevel)
            let to = place(segment.end, segment.endLevel)

            switch segment.kind {
            case .inhale, .exhale:
                // An S-curve, like the session orb's smoothstepped scale and the
                // site's own drawn breaths: a breath does not change pace at its
                // boundaries.
                let middle = (from.x + to.x) / 2
                commands.append(
                    .curve(
                        to: to,
                        control1: CGPoint(x: middle, y: from.y),
                        control2: CGPoint(x: middle, y: to.y)
                    )
                )
            case .holdIn, .holdOut:
                commands.append(.line(to: to))
            }
        }

        self.init(strokes: [
            Self.baseline(y: Self.derivedBaseline),
            Stroke(.accent, commands),
            Self.dot(x: start.x, y: start.y),
        ])
    }
}
