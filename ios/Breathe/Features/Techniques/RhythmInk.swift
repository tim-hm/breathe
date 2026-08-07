import BreatheKit
import BreatheUI
import SwiftUI

/// The three inks a breathing rhythm is drawn in: one for filling, one for
/// emptying, one for the moments nothing moves.
///
/// It extends the session player's colour language rather than inventing a
/// second one — `BreathVisual` already draws a held breath in the stillness
/// slate and a moving one in the goal's accent, so a hold is the same colour on
/// the chart as it is in the session. What the chart adds is direction, because
/// a line that rises and falls in one colour tells you the shape of the exercise
/// and nothing about which half you are on.
///
/// The exhale is the accent softened towards the ground rather than a second
/// hue. Two hues was the first attempt and neither form of it survives contact
/// with the palette: mixing an accent towards a fixed cool token turns the warm
/// ones muddy, and handing the exhale a fixed token outright collides on the
/// calm goal, which already owns the coolest accent there is — and calm is box
/// breathing, the exercise most people will ever see this on. Softening along
/// the accent's own hue cannot collide with anything, and it resolves correctly
/// in both appearances by construction: over white the exhale pales, over
/// near-black it dims.
///
/// Feature-local rather than in `BreatheStyle`: only this app draws a rhythm.
/// The wrist has `BreathRing`, which has room for one shape and no second half
/// to distinguish.
enum RhythmInk: CaseIterable {
    /// The lungs filling.
    case rising
    /// The lungs emptying — the half that does the settling.
    case falling
    /// A breath held, in or out.
    case held

    init(_ kind: PhaseKind) {
        switch kind {
        case .inhale: self = .rising
        case .exhale: self = .falling
        case .holdIn, .holdOut: self = .held
        }
    }

    /// What this ink resolves to against an exercise's goal accent.
    func colour(on accent: Color) -> Color {
        switch self {
        case .rising: accent
        case .falling: accent.mix(with: Theme.Surface.ground, by: 0.45)
        case .held: Theme.Accent.still
        }
    }

    /// The word for the key under the chart. Lowercase, because the key is a
    /// gloss on a picture rather than a sentence.
    var word: String {
        switch self {
        case .rising: "in"
        case .falling: "out"
        case .held: "hold"
        }
    }

    /// The inks `rhythm` actually uses, in reading order. A key naming a colour
    /// the chart never draws is worse than no key.
    static func present(in rhythm: BreathRhythm) -> [RhythmInk] {
        let used = Set(rhythm.segments.map { RhythmInk($0.kind) })
        return allCases.filter(used.contains)
    }
}
