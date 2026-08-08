import Foundation
@testable import OndUI
import Testing

/// The catalogue's failure modes are all silent ones. A `ColorToken` whose name
/// no longer matches an asset resolves to black, because `Color(_:bundle:)` is
/// not failable; a colourset missing its dark entry looks right all day and
/// unreadable at night. Neither is a compile error and neither is a crash, so
/// they are checked here.
///
/// Against the catalogue on disk rather than a resolved `Color`: SwiftPM's own
/// build copies an asset catalogue verbatim instead of running actool over it —
/// only Xcode compiles one — so on the host, where these tests run, there is no
/// `Assets.car` for the platform to resolve a name against. The JSON is the same
/// source of truth either way, and `mise run ios:build` is what proves actool
/// accepts it.
@Suite("Theme colours")
struct ThemeColorTests {
    /// Both directions at once: the token names a colourset, and that colourset
    /// was drawn for both appearances. Every colour in this palette is tuned per
    /// appearance, so one entry — or two carrying the same value — is a mistake
    /// rather than a choice.
    @Test(
        "every token names a colourset drawn for both appearances",
        arguments: ColorToken.allCases
    )
    func tokenAdaptsToAppearance(_ token: ColorToken) throws {
        let colorSet = try #require(
            try ColorSet(at: ColorSet.palette, named: token.rawValue),
            "\(token.rawValue) is missing from Colors.xcassets"
        )

        #expect(colorSet.dark != nil, "\(token.rawValue) has no dark entry")
        #expect(
            colorSet.dark?.color != colorSet.light?.color,
            "\(token.rawValue) is the same colour in both appearances"
        )
    }

    /// The other direction: a colourset nothing names is dead weight at best,
    /// and at worst the survivor of a rename that left the token pointing at
    /// nothing.
    @Test("every colourset in the catalogue is named by a token")
    func catalogueHasNoOrphans() throws {
        let named = Set(ColorToken.allCases.map(\.rawValue))
        let filed = try ColorSet.namesInCatalogue(at: ColorSet.palette)

        #expect(!filed.isEmpty)
        #expect(filed.subtracting(named).isEmpty)
    }

    /// Every ink is drawn on one of the two grounds, and every one of them
    /// carries `.caption`, `.caption2` or `.footnote` copy somewhere — so the
    /// bar is AA's 4.5:1 for normal text throughout, with no large-text
    /// allowance to fall back on.
    ///
    /// Measured from the catalogue rather than checked by eye because the
    /// failure this replaced was invisible: `Ink/Tertiary` sat at 2.72:1 in the
    /// light appearance for as long as it shipped, and looked like a design
    /// choice.
    @Test(
        "every ink clears WCAG AA on every ground, on every surface",
        arguments: inks,
        grounds
    )
    func inkIsLegibleOnEveryGround(_ ink: ColorToken, _ ground: ColorToken) throws {
        let inkSet = try #require(try ColorSet(at: ColorSet.palette, named: ink.rawValue))
        let groundSet = try #require(try ColorSet(at: ColorSet.palette, named: ground.rawValue))

        for appearance in Appearance.allCases {
            let foreground = try #require(inkSet[appearance]?.color)
            let background = try #require(groundSet[appearance]?.color)

            try expectAA(
                foreground,
                on: background,
                "\(ink.rawValue) on \(ground.rawValue)",
                appearance
            )
        }
    }

    /// A badge sets a word in primary ink over a 0.15 wash of an accent —
    /// `GoalBadge` is the one that names a technique's goal. Drawn the obvious
    /// way instead, with the accent carrying the text, four of the five goal
    /// accents miss AA in the light appearance, so the treatment that replaced
    /// it is worth holding: retune an accent and this is what notices.
    @Test("primary ink stays legible over a 0.15 wash of any accent", arguments: accents, grounds)
    func inkIsLegibleOverAnAccentWash(_ accent: ColorToken, _ ground: ColorToken) throws {
        let accentSet = try #require(try ColorSet(at: ColorSet.palette, named: accent.rawValue))
        let groundSet = try #require(try ColorSet(at: ColorSet.palette, named: ground.rawValue))
        let inkSet = try #require(try ColorSet(
            at: ColorSet.palette,
            named: ColorToken.inkPrimary.rawValue
        ))

        for appearance in Appearance.allCases {
            let foreground = try #require(inkSet[appearance]?.color)
            let wash = try #require(accentSet[appearance]?.color)
            let ground = try #require(groundSet[appearance]?.color)
            let background = try #require(wash.blended(over: ground, alpha: 0.15))

            try expectAA(
                foreground,
                on: background,
                "Ink/Primary on \(accent.rawValue) at 0.15",
                appearance
            )
        }
    }

    /// The session player washes a goal's accent over the ground at
    /// `Theme.Wash.strongest` and reads text on top of it. The wash drags the
    /// ground towards mid-luminance from whichever end it started, so this is
    /// the tightest background in the app and the only ink that survives it is
    /// the primary one — which is why `accentGround(_:)` documents that and why
    /// this measures it.
    ///
    /// Against `Theme.Wash.strongest` rather than a literal, so strengthening
    /// the wash is what fails here: the position line and the nostril hint were
    /// unreadable for as long as the accent behind them was nobody's measured
    /// value.
    @Test("primary ink clears WCAG AA over the strongest accent wash", arguments: accents)
    func primaryInkIsLegibleOverTheAccentGround(_ accent: ColorToken) throws {
        let accentSet = try #require(try ColorSet(at: ColorSet.palette, named: accent.rawValue))
        let groundSet = try #require(try ColorSet(
            at: ColorSet.palette,
            named: ColorToken.surfaceGround.rawValue
        ))
        let inkSet = try #require(try ColorSet(
            at: ColorSet.palette,
            named: ColorToken.inkPrimary.rawValue
        ))

        for appearance in Appearance.allCases {
            let foreground = try #require(inkSet[appearance]?.color)
            let wash = try #require(accentSet[appearance]?.color)
            let ground = try #require(groundSet[appearance]?.color)
            let background = try #require(wash.blended(over: ground, alpha: Theme.Wash.strongest))

            try expectAA(
                foreground,
                on: background,
                "Ink/Primary on \(accent.rawValue) at \(Theme.Wash.strongest)",
                appearance
            )
        }
    }

    /// A technique figure strokes its exhale in the goal's accent softened
    /// towards the ground (`OndStyle/FigureShape.swift`). That is a graphical
    /// object rather than text, so the bar is WCAG 1.4.11's 3:1 — and it is the
    /// load-bearing mark on the drawing, the one telling the two halves of a
    /// breath apart.
    ///
    /// Against `Surface/Ground` alone, unlike the ink tests above: every screen
    /// that draws a figure grounds itself with `paletteGround()`, and the list
    /// rows carrying the small ones are transparent over it, so a figure never
    /// sits on a card. There would be nothing spare if one ever did —
    /// `Accent/Settle` softened lands three thousandths under 3:1 on
    /// `Surface/Raised` — which is the reason to come back here and measure the
    /// pair rather than assume this one carries over.
    @Test("every softenable accent survives being softened", arguments: softenable)
    func softenedAccentIsPerceivableOnItsGround(_ accent: ColorToken) throws {
        let accentSet = try #require(try ColorSet(at: ColorSet.palette, named: accent.rawValue))
        let groundSet = try #require(try ColorSet(
            at: ColorSet.palette,
            named: ColorToken.surfaceGround.rawValue
        ))

        for appearance in Appearance.allCases {
            let ground = try #require(groundSet[appearance]?.color)
            let full = try #require(accentSet[appearance]?.color)
            let softened = try #require(
                full.softened(towards: ground, by: Theme.Softening.strongest)
            )
            let ratio = try #require(softened.contrast(against: ground))

            #expect(
                ratio >= 3,
                """
                \(accent.rawValue) softened by \(Theme.Softening.strongest) is \
                \(ratio.formatted(.number.precision(.fractionLength(2)))):1 in \
                \(appearance.rawValue), below WCAG 1.4.11's 3:1
                """
            )
        }
    }

    /// AA's 4.5:1 for normal text. Reported with the measured figure, because a
    /// bare "below 4.5" leaves whoever retunes the colour guessing how far.
    private func expectAA(
        _ foreground: CatalogueColor,
        on background: CatalogueColor,
        _ pair: String,
        _ appearance: Appearance
    ) throws {
        let ratio = try #require(foreground.contrast(against: background))

        #expect(
            ratio >= 4.5,
            """
            \(pair) is \(ratio.formatted(.number.precision(.fractionLength(2)))):1 \
            in \(appearance.rawValue), below AA's 4.5:1
            """
        )
    }

    /// watchOS resolves the Any slot rather than an appearance, so each token
    /// carries a hand-copied watch entry holding its dark value. A hand copy is
    /// a thing that drifts, and the drift shows up as light-mode ink on an
    /// always-black screen — on the device with no way to change the setting.
    @Test("every token's watch entry carries its dark value", arguments: ColorToken.allCases)
    func watchMirrorsTheDarkAppearance(_ token: ColorToken) throws {
        let colorSet = try #require(try ColorSet(at: ColorSet.palette, named: token.rawValue))

        #expect(
            colorSet.watch?.color == colorSet.dark?.color,
            "\(token.rawValue)'s watch entry does not match its dark entry"
        )
    }

    /// The app's own catalogue carries one colour, `AccentColor`, because the
    /// system tints its controls from an asset in the app bundle and cannot read
    /// a package's. That makes it a hand-kept copy of `Accent/Brand`, and the app
    /// target has no test bundle — so this is the only place that can see both
    /// files and notice when someone retunes one of them.
    @Test("the app's global accent still matches the palette's brand")
    func appAccentMirrorsTheBrand() throws {
        let brand = try #require(try ColorSet(at: ColorSet.palette, named: "Accent/Brand"))
        let appAccent = try #require(try ColorSet(at: ColorSet.appCatalogue, named: "AccentColor"))

        #expect(appAccent.light?.color == brand.light?.color)
        #expect(appAccent.dark?.color == brand.dark?.color)
    }
}

/// Every ink, and every accent, derived rather than listed: a fourth step of
/// emphasis added to `ColorToken` and then never measured is the same silent gap
/// this file exists to close.
private let inks = ColorToken.allCases.filter { $0.rawValue.hasPrefix("Ink/") }
private let accents = ColorToken.allCases.filter { $0.rawValue.hasPrefix("Accent/") }
/// The accents something can ask for a quieter version of. Derived with two
/// exclusions rather than listed, on the same terms as the line above, so a sixth
/// goal accent is measured the day it is added: `Accent/Still` is drawn on a
/// figure but never softened — a hold is the stillness slate at full strength —
/// and `Accent/Caution` never strokes one. `Accent/Brand` stays in even though no
/// goal wears it, because the marketing site strokes its figures in a softened
/// brand and states the result as a hex nothing else measures.
private let softenable = accents.filter { $0 != .accentStill && $0 != .accentCaution }
/// `Surface/Line` is a hairline and never carries text, which is why the grounds
/// are named rather than derived from the prefix.
private let grounds: [ColorToken] = [.surfaceGround, .surfaceRaised]
