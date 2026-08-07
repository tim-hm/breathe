import OndKit
import OndUI
import SwiftUI

/// A technique figure's strokes as SwiftUI paths, and the palette they resolve
/// in.
///
/// Lives in `OndStyle` because that is the one target allowed to know about both
/// a domain type and a design token — and because the phone and the watch both
/// draw these. The renderer that was duplicated between them was ninety lines of
/// mechanical `switch` over a command enum, and the duplication only ever earned
/// its keep while the two drew *different* figures. They no longer do.
///
/// The fit itself is not here: `TechniqueFigure.transform(into:inset:)` owns it,
/// in `OndKit`, so the site's generator can apply the same rule without reaching
/// through SwiftUI. Two copies of it would be the one divergence
/// `mise run check:diagrams` could never catch.
///
/// What stays per-app is everything above this: sizes, labels, layout, and how
/// much of the figure a surface chooses to show.
public struct FigureShape: Shape {
    public let commands: [TechniqueFigure.Command]
    /// The whole figure's extent, so every stroke of one drawing shares a
    /// transform and the baseline still lines up under the curve.
    public let bounds: CGRect
    /// Room for the stroke's own width, which straddles the path.
    public let inset: CGFloat

    public init(commands: [TechniqueFigure.Command], bounds: CGRect, inset: CGFloat) {
        self.commands = commands
        self.bounds = bounds
        self.inset = inset
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()

        for command in commands {
            switch command {
            case let .move(point):
                path.move(to: point)
            case let .line(point):
                path.addLine(to: point)
            case let .quadCurve(point, control):
                path.addQuadCurve(to: point, control: control)
            case let .curve(point, control1, control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            case let .circle(centre, radius):
                path.addEllipse(in: CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }

        return path.applying(
            TechniqueFigure.transform(fitting: bounds, into: rect, inset: inset)
        )
    }
}

public extension TechniqueFigure.Ink {
    /// What this ink resolves to against an exercise's goal accent.
    ///
    /// Extends the session player's colour language rather than inventing a
    /// second one — `BreathVisual` already draws a held breath in the stillness
    /// slate and a moving one in the goal's accent, so a hold is the same colour
    /// on the figure as it is in the session. What the figure adds is direction,
    /// because a line that rises and falls in one colour tells you the shape of
    /// the exercise and nothing about which half you are on.
    ///
    /// The exhale is the accent softened towards the ground rather than a second
    /// hue. Two hues was the first attempt and neither form of it survives
    /// contact with the palette: mixing an accent towards a fixed cool token
    /// turns the warm ones muddy, and handing the exhale a fixed token outright
    /// collides on the calm goal, which already owns the coolest accent there is
    /// — and calm is box breathing, the exercise most people will ever see this
    /// on. Softening along the accent's own hue cannot collide with anything,
    /// and it resolves correctly in both appearances by construction: over white
    /// the exhale pales, over near-black it dims.
    func colour(on accent: Color) -> Color {
        switch self {
        case .inhale: accent
        case .exhale: accent.mix(with: Theme.Surface.ground, by: 0.45)
        case .hold: Theme.Accent.still
        // The site draws its baselines at 40% of the body ink. Here that is the
        // palette's own faintest step, which already resolves per appearance.
        case .baseline: Theme.Ink.tertiary.opacity(0.5)
        }
    }
}

public extension TechniqueFigure.Stroke {
    /// How heavily to draw this stroke, relative to a figure's line width.
    ///
    /// A baseline is reference rather than subject, so it is drawn at a hairline
    /// whatever weight the figure carries. One rule, because all three renderers
    /// were spelling out the same ternary.
    func weight(on lineWidth: CGFloat) -> CGFloat {
        role == .baseline ? 1 : lineWidth
    }
}
