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
    /// The weight this figure is stroked at, so the fit can leave room for it.
    public let lineWidth: CGFloat

    public init(commands: [TechniqueFigure.Command], bounds: CGRect, lineWidth: CGFloat) {
        self.commands = commands
        self.bounds = bounds
        self.lineWidth = lineWidth
    }

    public func path(in rect: CGRect) -> Path {
        // Placed as each point is added rather than by transforming the finished
        // path: SwiftUI calls this on every layout pass for every stroke of
        // every visible figure, and `applying` walks the whole path a second
        // time to build a second one.
        let fit = TechniqueFigure.transform(fitting: bounds, into: rect, lineWidth: lineWidth)
        var path = Path()

        for command in commands {
            switch command {
            case let .move(point):
                path.move(to: point.applying(fit))
            case let .line(point):
                path.addLine(to: point.applying(fit))
            case let .quadCurve(point, control):
                path.addQuadCurve(to: point.applying(fit), control: control.applying(fit))
            case let .curve(point, control1, control2):
                path.addCurve(
                    to: point.applying(fit),
                    control1: control1.applying(fit),
                    control2: control2.applying(fit)
                )
            case let .circle(centre, radius):
                let placed = centre.applying(fit)
                // Uniform scale, so either axis gives the placed radius.
                let scaled = radius * fit.a
                path.addEllipse(in: CGRect(
                    x: placed.x - scaled,
                    y: placed.y - scaled,
                    width: scaled * 2,
                    height: scaled * 2
                ))
            }
        }

        return path
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
    ///
    /// How far it softens is `Theme.Softening.strongest` rather than a number
    /// chosen here, because the fraction that reads as *soft* and the fraction
    /// that still clears 3:1 against the ground are one decision, and this is the
    /// stroke that decision is measured on. Two things the next reader is likely
    /// to try, and neither is an improvement: raising it, when the 0.45 this used
    /// to take is illegal on every accent over white; and splitting it per
    /// appearance, which the palette's own ceiling makes unnecessary and which
    /// would make this the one place in either app reading `colorScheme` by hand.
    func colour(on accent: Color) -> Color {
        switch self {
        case .inhale: accent
        case .exhale: accent.mix(with: Theme.Surface.ground, by: Theme.Softening.strongest)
        case .hold: Theme.Accent.still
        // The site draws its baselines at 40% of the body ink. Here that is the
        // palette's own faintest step, which already resolves per appearance.
        case .baseline: Theme.Ink.tertiary.opacity(0.5)
        }
    }
}
