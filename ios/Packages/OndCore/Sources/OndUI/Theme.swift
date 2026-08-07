import SwiftUI

/// The visual language, in one place.
///
/// Every colour resolves from `Colors.xcassets` in this target, where each token
/// carries a light and a dark value. That is the whole of the app's dark mode:
/// the system picks a variant per appearance, so no view branches on
/// `colorScheme` and no screen can be themed for only one of them.
///
/// Each token also carries an Apple Watch idiom entry holding its dark value,
/// because watchOS resolves the Any slot rather than an appearance — without it
/// the wrist renders light-mode ink on an always-black screen. A new colour is
/// not done until it has all three values.
///
/// The palette is the marketing site's (`web/style.css`) — sea glass on white,
/// sea glass on a near-black with a green cast — so the app and the page a
/// person arrives from are recognisably the same product.
///
/// Deliberately holds no domain types — this package knows nothing about
/// techniques or goals, which is what keeps the dependency pointing one way
/// (docs/code-structure.md). Mapping a domain value onto an accent is
/// `OndStyle`'s job: it depends on this module and on `OndKit`, so both
/// apps read one mapping without this one learning anything.
public enum Theme {
    /// A four-step scale. Constraining spacing to four values is what keeps a
    /// minimal interface looking deliberate rather than merely sparse.
    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let close: CGFloat = 8
        public static let standard: CGFloat = 16
        public static let loose: CGFloat = 24
    }

    /// Corner radii. Its own scale rather than a reach into `Spacing`: a radius
    /// that borrows a gap's value is tied to it by coincidence, and retuning the
    /// space between two labels would reshape every card on the way past.
    public enum Radius {
        public static let card: CGFloat = 16
    }

    /// The grounds content sits on. A screen that draws its own background — the
    /// session player, which covers the system's — picks from here rather than
    /// leaving whatever the presentation happened to put behind it.
    public enum Surface {
        /// The base of the app: white, or the near-black the wordmark sits on.
        public static let ground = ColorToken.surfaceGround.color
        /// One step off the ground, for anything meant to read as a card.
        public static let raised = ColorToken.surfaceRaised.color
        /// Hairlines — a stroke or a divider, never a fill.
        public static let line = ColorToken.surfaceLine.color
    }

    /// Text, in three steps of emphasis. Tinted towards the palette rather than
    /// neutral grey, which is what stops a screen of body copy reading as
    /// system-default next to the accents.
    ///
    /// At full opacity all three clear WCAG AA for normal text — 4.5:1 —
    /// against both `Surface` grounds in both appearances, which
    /// `ThemeColorTests` measures rather than takes on trust. Every ink is used
    /// at `.caption` or `.footnote` somewhere, so none of them qualifies for the
    /// 3:1 large-text allowance, and the scale has less room at the quiet end
    /// than it looks like it should. Fading one with `.opacity` spends that
    /// margin and is nobody's measured value.
    public enum Ink {
        /// Body and headings.
        public static let primary = ColorToken.inkPrimary.color
        /// Supporting copy: a summary under a title, a caption under a number.
        public static let secondary = ColorToken.inkSecondary.color
        /// Present but receding — a disclaimer, a hint someone has already read.
        ///
        /// As faint as AA allows and no fainter: against `Surface.raised`, the
        /// tighter of the two grounds, it measures 4.55:1. The pair it replaced
        /// looked more recessive and measured 2.72:1 there, so a step further
        /// back is not available.
        public static let tertiary = ColorToken.inkTertiary.color
    }

    /// Accents, named for the feeling rather than the colour, so a palette
    /// change is a one-line edit here instead of a search across views.
    ///
    /// The five goal accents walk one arc of the wheel, green through teal and
    /// blue to indigo, with amber opposite: related enough to look like one
    /// palette, separated enough to tell apart at badge size.
    public enum Accent {
        /// The wordmark's teal — the app's own colour, for anything no technique
        /// owns. Onboarding and the paywall live here.
        public static let brand = ColorToken.accentBrand.color
        /// Cool sea blue — settling.
        public static let settle = ColorToken.accentSettle.color
        /// Deep indigo — night.
        public static let night = ColorToken.accentNight.color
        /// Warm amber — activating.
        public static let spark = ColorToken.accentSpark.color
        /// Muted green — recovery.
        public static let restore = ColorToken.accentRestore.color
        /// Deep teal — attention held on something.
        public static let attend = ColorToken.accentAttend.color
        /// Slate blue — suspension, nothing moving. Named for the feeling like
        /// the rest: the feature decides which of its moments are still ones.
        public static let still = ColorToken.accentStill.color
        /// Rust — a caution worth reading. Kept well round the wheel from
        /// `spark` so the energising accent never reads as a warning.
        public static let caution = ColorToken.accentCaution.color
    }
}
