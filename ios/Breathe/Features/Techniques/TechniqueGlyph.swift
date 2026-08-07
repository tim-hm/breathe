import BreatheKit
import BreatheUI
import SwiftUI

/// A technique's identity, at row size: the marketing site's own line drawing
/// for it, in the technique's goal accent.
///
/// It replaced a generic fullness curve, which drew every technique in one
/// grammar and so told you almost nothing — box breathing and 4-7-8 came out as
/// near-identical trapezoids. The site never made that mistake: it draws a
/// square for box, a sine about a midline for coherent, a rise-hold-descend
/// timeline for 4-7-8. `TechniqueDrawing` holds those coordinates; this view
/// only turns them into a path.
///
/// Not to be confused with `BreathRhythmChart` on the detail screen. That one is
/// duration-accurate and redraws as the Advanced dials move; this one is a
/// portrait, and identical for every dialling of the same technique.
struct TechniqueGlyph: View {
    let technique: Technique
    /// The line weight. Sized by the caller because the same drawing appears at
    /// row scale and at page scale, and 1.5pt — the site's weight — is a hairline
    /// at either extreme of that range.
    var lineWidth: CGFloat = 1.4

    var body: some View {
        let drawing = TechniqueDrawing(technique: technique)

        GeometryReader { geometry in
            ForEach(Array(drawing.strokes.enumerated()), id: \.offset) { _, stroke in
                DrawnStroke(stroke: stroke, bounds: drawing.bounds, inset: lineWidth)
                    .stroke(
                        colour(stroke.ink),
                        style: StrokeStyle(
                            lineWidth: stroke.ink == .faint ? 1 : lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        // Decoration: the row's name, summary, and shape line carry the facts,
        // and VoiceOver reads them as one element without this in the way.
        .accessibilityHidden(true)
    }

    private func colour(_ ink: TechniqueDrawing.Ink) -> Color {
        switch ink {
        case .accent: technique.goal.accent
        // The site draws its baselines at 40% of the body ink. Here that is the
        // palette's own faintest step, which already resolves per appearance.
        case .faint: Theme.Ink.tertiary.opacity(0.5)
        }
    }
}

/// One stroke of a drawing, scaled into whatever the caller offers.
///
/// Uniform and centred, fitted to the drawing's ink rather than to the design
/// box: the site's figures leave wide margins for text labels the app does not
/// draw, so fitting the whole viewBox would shrink every picture to fit
/// whitespace that is not there. Uniform because stretching would oval the start
/// dot and turn box breathing's square into a rectangle — which is the one thing
/// that drawing exists to say.
struct DrawnStroke: Shape {
    let stroke: TechniqueDrawing.Stroke
    /// The whole drawing's extent, so every stroke shares one transform and the
    /// baseline still lines up under the curve.
    let bounds: CGRect
    /// Room for the stroke's own width, which straddles the path.
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        for command in stroke.commands {
            switch command {
            case let .move(point):
                path.move(to: point)
            case let .line(point):
                path.addLine(to: point)
            case let .curve(point, control1, control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            case let .circle(centre, radius):
                path.addEllipse(
                    in: CGRect(
                        x: centre.x - radius,
                        y: centre.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
            case let .roundedRect(box, radius):
                path.addRoundedRect(in: box, cornerSize: CGSize(width: radius, height: radius))
            }
        }

        let available = rect.insetBy(dx: inset, dy: inset)
        guard bounds.width > 0, bounds.height > 0, available.width > 0, available.height > 0 else {
            return path
        }

        let scale = min(available.width / bounds.width, available.height / bounds.height)
        return path.applying(
            CGAffineTransform(
                translationX: rect.midX - bounds.midX * scale,
                y: rect.midY - bounds.midY * scale
            )
            .scaledBy(x: scale, y: scale)
        )
    }
}
