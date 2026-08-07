import OndUI
import SwiftUI

/// A line drawing for one foundation topic — the idea in the answer, sketched
/// at one stroke weight so a scroll through the basics reads as a single hand.
///
/// Keyed on the topic's slug, not its position: the topics arrive from the
/// seeded catalogue, so their wording and their order can both change without
/// the app shipping. A slug this file has never heard of draws nothing at all,
/// which is what lets the backend add a topic before the app has a picture for
/// it — a gap in the sketches, never a wrong one and never a crash.
struct FoundationIllustration: View {
    /// The topic's stable key, as seeded.
    let slug: String

    private static let height: CGFloat = 120

    var body: some View {
        switch slug {
        case "why-it-works": sketch(Sketches.seesaw)
        case "belly-or-chest": sketch(Sketches.torso)
        case "nose-or-mouth": sketch(Sketches.profile)
        case "how-to-exhale": sketch(Sketches.plume)
        case "how-slow": sketch(Sketches.waves)
        case "sitting-or-lying": sketch(Sketches.postures)
        case "eyes-open-or-closed": sketch(Sketches.eyes)
        default: EmptyView()
        }
    }

    private func sketch(_ strokes: [Stroke]) -> some View {
        Sketch(strokes: strokes)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            // Decoration. The question and answer beneath carry the meaning,
            // and VoiceOver reads them as one element without this in the way.
            .accessibilityHidden(true)
    }
}

/// One pen stroke: where it goes, and the colour it goes in.
private struct Stroke {
    let color: Color
    /// Draws into the design box — a fixed 240×120 grid, y downwards, so every
    /// sketch is authored at one scale and fitted to the row afterwards.
    ///
    /// `@Sendable` because the shape that ends up holding it is a `Shape`, and
    /// `Shape` is `Sendable` in the Swift 6 language mode.
    let draw: @Sendable (inout Path) -> Void
}

/// Lays strokes over each other in the design box.
private struct Sketch: View {
    static let design = CGSize(width: 240, height: 120)

    let strokes: [Stroke]

    var body: some View {
        ZStack {
            ForEach(Array(strokes.enumerated()), id: \.offset) { _, stroke in
                Fitted(draw: stroke.draw)
                    .stroke(
                        stroke.color,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}

/// Scales a design-box path into whatever the row offers, uniformly and
/// centred. Uniform is the point: stretching to fill would oval the eyes and
/// flatten the seesaw's weights into lozenges.
private struct Fitted: Shape {
    let draw: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        draw(&path)

        let design = Sketch.design
        let scale = min(rect.width / design.width, rect.height / design.height)
        return path.applying(
            CGAffineTransform(
                translationX: rect.midX - design.width * scale / 2,
                y: rect.midY - design.height * scale / 2
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

/// The drawings themselves, one per slug.
///
/// Each holds to the same two-tone rule: structure in ink, and exactly one
/// stroke in the accent — the thing the answer recommends. That is what makes
/// a sketch legible without a caption, since none of them carry text.
private enum Sketches {
    private static let ink = Theme.Ink.secondary
    private static let faint = Theme.Ink.tertiary
    private static let accent = Theme.Accent.settle

    /// Why it works: breath as the lever on the nervous system. The out-breath
    /// is the heavier end, and the beam tips towards it.
    static var seesaw: [Stroke] {
        [
            Stroke(color: faint) { path in
                path.move(to: pt(64, 100))
                path.addLine(to: pt(176, 100))
            },
            Stroke(color: ink) { path in
                path.move(to: pt(104, 100))
                path.addLine(to: pt(120, 68))
                path.addLine(to: pt(136, 100))
            },
            Stroke(color: ink) { path in
                path.move(to: pt(34, 50))
                path.addLine(to: pt(206, 86))
            },
            Stroke(color: faint) { path in
                path.addEllipse(in: CGRect(x: 27, y: 34, width: 14, height: 14))
            },
            Stroke(color: accent) { path in
                path.addEllipse(in: CGRect(x: 194, y: 60, width: 24, height: 24))
            },
        ]
    }

    /// Belly or chest: the same torso twice, the accent outline dropping the
    /// breath low enough to move the hand resting under the ribs.
    static var torso: [Stroke] {
        [
            Stroke(color: ink) { path in
                path.addEllipse(in: CGRect(x: 89, y: 8, width: 22, height: 22))
                path.move(to: pt(86, 38))
                path.addQuadCurve(to: pt(90, 102), control: pt(80, 72))
                path.addLine(to: pt(108, 102))
                path.move(to: pt(86, 38))
                path.addQuadCurve(to: pt(114, 42), control: pt(100, 34))
            },
            Stroke(color: faint) { path in
                path.move(to: pt(114, 42))
                path.addCurve(to: pt(108, 102), control1: pt(118, 62), control2: pt(114, 84))
            },
            Stroke(color: accent) { path in
                path.move(to: pt(114, 42))
                path.addCurve(to: pt(108, 102), control1: pt(120, 60), control2: pt(156, 90))
            },
            Stroke(color: ink) { path in
                path.move(to: pt(136, 74))
                path.addQuadCurve(to: pt(136, 94), control: pt(146, 84))
            },
        ]
    }

    /// In through the nose: a profile, with the air arriving by the long way
    /// round rather than straight in at the mouth.
    static var profile: [Stroke] {
        [
            Stroke(color: ink) { path in
                path.move(to: pt(118, 14))
                path.addCurve(to: pt(152, 66), control1: pt(144, 14), control2: pt(154, 38))
                path.addLine(to: pt(148, 88))
                path.addQuadCurve(to: pt(104, 100), control: pt(128, 104))
                path.addQuadCurve(to: pt(94, 86), control: pt(94, 96))
                path.addQuadCurve(to: pt(98, 80), control: pt(92, 82))
                path.addLine(to: pt(96, 74))
                path.addQuadCurve(to: pt(78, 68), control: pt(88, 76))
                path.addLine(to: pt(96, 50))
                path.addQuadCurve(to: pt(98, 42), control: pt(92, 44))
                path.addCurve(to: pt(118, 14), control1: pt(100, 28), control2: pt(104, 18))
            },
            Stroke(color: accent) { path in
                path.move(to: pt(16, 96))
                path.addCurve(to: pt(76, 72), control1: pt(42, 98), control2: pt(50, 84))
            },
            Stroke(color: faint) { path in
                path.move(to: pt(20, 110))
                path.addCurve(to: pt(80, 80), control1: pt(50, 112), control2: pt(58, 94))
            },
        ]
    }

    /// And out through what: pursed lips, and a breath with somewhere to go —
    /// the accent stream long and level, the way a good exhale leaves.
    static var plume: [Stroke] {
        [
            Stroke(color: ink) { path in
                path.addEllipse(in: CGRect(x: 26, y: 52, width: 18, height: 14))
            },
            Stroke(color: accent) { path in
                path.move(to: pt(50, 59))
                path.addCurve(to: pt(224, 58), control1: pt(112, 52), control2: pt(168, 60))
            },
            Stroke(color: faint) { path in
                path.move(to: pt(50, 54))
                path.addCurve(to: pt(196, 22), control1: pt(102, 40), control2: pt(150, 26))
                path.move(to: pt(50, 64))
                path.addCurve(to: pt(196, 96), control1: pt(102, 80), control2: pt(150, 92))
            },
        ]
    }

    /// How slow: the everyday breath behind, and over it the long even swell of
    /// five or six a minute.
    static var waves: [Stroke] {
        [
            Stroke(color: faint) { path in
                wave(into: &path, humps: 14, reach: 14)
            },
            Stroke(color: accent) { path in
                wave(into: &path, humps: 3, reach: 40)
            },
        ]
    }

    /// Sit or lie down: upright for anything alerting, flat for anything meant
    /// to end in sleep — one drawing because the choice is between them.
    static var postures: [Stroke] {
        [
            Stroke(color: faint) { path in
                path.move(to: pt(16, 104))
                path.addLine(to: pt(104, 104))
                path.move(to: pt(136, 104))
                path.addLine(to: pt(224, 104))
                path.move(to: pt(120, 28))
                path.addLine(to: pt(120, 96))
            },
            Stroke(color: accent) { path in
                path.addEllipse(in: CGRect(x: 34, y: 22, width: 20, height: 20))
                path.move(to: pt(44, 44))
                path.addLine(to: pt(42, 76))
                path.addLine(to: pt(74, 78))
                path.addLine(to: pt(76, 104))
            },
            Stroke(color: ink) { path in
                path.addEllipse(in: CGRect(x: 140, y: 84, width: 20, height: 20))
                path.move(to: pt(162, 98))
                path.addQuadCurve(to: pt(196, 100), control: pt(180, 88))
                path.addQuadCurve(to: pt(218, 104), control: pt(210, 88))
            },
        ]
    }

    /// Eyes open or closed: both offered, the closed one in the accent because
    /// it is the simpler place to start.
    static var eyes: [Stroke] {
        [
            Stroke(color: ink) { path in
                path.move(to: pt(18, 62))
                path.addQuadCurve(to: pt(94, 62), control: pt(56, 26))
                path.addQuadCurve(to: pt(18, 62), control: pt(56, 92))
                path.addEllipse(in: CGRect(x: 44, y: 48, width: 24, height: 24))
            },
            Stroke(color: ink) { path in
                path.addEllipse(in: CGRect(x: 52, y: 56, width: 8, height: 8))
            },
            Stroke(color: accent) { path in
                path.move(to: pt(146, 54))
                path.addQuadCurve(to: pt(222, 54), control: pt(184, 84))
                path.move(to: pt(160, 74))
                path.addLine(to: pt(156, 86))
                path.move(to: pt(184, 80))
                path.addLine(to: pt(184, 92))
                path.move(to: pt(208, 74))
                path.addLine(to: pt(212, 86))
            },
        ]
    }

    /// Alternating humps across the box, one cubic each. `reach` is how far the
    /// control points pull off the midline rather than the height the curve
    /// reaches — a cubic only travels three quarters of the way to its
    /// controls, so the drawn wave is shallower than the number suggests.
    private static func wave(into path: inout Path, humps: Int, reach: CGFloat) {
        let startX: CGFloat = 12
        let endX: CGFloat = 228
        let midline: CGFloat = 60
        let step = (endX - startX) / CGFloat(humps)

        path.move(to: pt(startX, midline))
        for hump in 0 ..< humps {
            let left = startX + CGFloat(hump) * step
            let pull = midline + (hump.isMultiple(of: 2) ? -reach : reach)
            path.addCurve(
                to: pt(left + step, midline),
                control1: pt(left + step / 2, pull),
                control2: pt(left + step / 2, pull)
            )
        }
    }
}
