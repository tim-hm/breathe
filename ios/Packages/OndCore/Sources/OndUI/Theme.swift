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

    /// How an accent is poured into glass.
    ///
    /// Its own scale rather than a reach into the opacities the opaque cards
    /// use: glass already carries luminance of its own, so the `0.18` that
    /// reads as a selected fill on `Surface.raised` disappears into it
    /// entirely. These are the strengths that survive the material.
    public enum Glass {
        /// A selected surface's accent. Roughly two and a half times the
        /// opaque card's tint, which is what it takes to be as legible.
        public static let selection: Double = 0.45
    }

    /// How strongly an accent is poured over `Surface.ground` when a whole
    /// screen wears a technique's colour.
    ///
    /// Its own scale rather than `Glass`'s: glass carries luminance of its own
    /// and these values go straight onto the ground, where they move it far
    /// enough to decide what can be read on top. At `strongest` the ground
    /// lands mid-luminance whichever accent it carries — `Ink.secondary`
    /// measures 3.26:1 there and `Ink.tertiary` 2.40:1, both below AA, while
    /// `Ink.primary` holds 7.01:1 at its worst. That is the whole reason this
    /// is a named ceiling instead of a literal beside a gradient: raising it is
    /// a legibility decision, and `ThemeColorTests` fails when it stops holding.
    public enum Wash {
        /// The top of the gradient, and the only value the guarantee is
        /// measured at — text can sit anywhere under it.
        public static let strongest: Double = 0.35
        /// The bottom of it, where the accent is barely present and the ground
        /// is almost the palette's own.
        public static let faintest: Double = 0.05
    }

    /// How far an accent is pulled towards the ground when a drawing needs a
    /// quieter version of the same colour.
    ///
    /// The mirror of `Wash`: that one pours an accent over the ground to tint
    /// it, this one pulls an accent towards the ground to hush it. What is
    /// softened this way is a line rather than text — the exhale stroke on a
    /// technique figure — so the bar is WCAG 1.4.11's 3:1 for a graphical object
    /// that carries meaning, not the 4.5:1 the inks answer to.
    ///
    /// One fraction for both appearances, which is the part worth reading before
    /// changing it. White has far less room than the near-black does: over the
    /// dark ground every accent stays legible softened as far as 0.42, and over
    /// white the tightest of them gives out at 0.24. But the two ranges overlap,
    /// so one number under the tighter ceiling serves both grounds, and splitting
    /// it in two would buy a little more separation in the dark appearance at the
    /// price of the invariant this palette is built on — that the asset catalogue
    /// is the whole of dark mode and no code branches on `colorScheme`.
    ///
    /// A named ceiling for the same reason `Wash.strongest` is one: raising it is
    /// a legibility decision, and `ThemeColorTests` fails when it stops holding.
    public enum Softening {
        /// The most an accent gives up while still reading as itself against the
        /// ground.
        ///
        /// `Accent/Settle` is the one that runs out first, and it hits the floor
        /// between 0.24 and 0.25 — 2.9971:1 at the latter, which passes nothing
        /// and rounds to a number that looks like it does. This sits well below
        /// that on purpose: at 0.20 the same worst case is 3.27:1, which is the
        /// margin a 1.6-point stroke wants before the next palette nudge spends
        /// it. The value it replaced, 0.45, cleared 3:1 on no accent at all in
        /// the light appearance, and on neither `Accent/Night` nor
        /// `Accent/Attend` in the dark one.
        public static let strongest: Double = 0.20
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
