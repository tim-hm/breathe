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
/// `Surface/Line` is a hairline and never carries text, which is why the grounds
/// are named rather than derived from the prefix.
private let grounds: [ColorToken] = [.surfaceGround, .surfaceRaised]

/// The three surfaces the palette is drawn for, so every contrast question here
/// is asked three times.
///
/// The watch is one of them rather than a copy of `dark` taken on trust:
/// `watchMirrorsTheDarkAppearance` is what makes the two agree today, and the
/// day a wrist entry is given a value of its own — the always-black screen is a
/// different rendering problem from a dark phone — the measurements have to
/// follow it there rather than keep reporting on the phone.
private enum Appearance: String, CaseIterable {
    case light
    case dark
    case watch
}

/// One `.colorset` as a catalogue stores it: an entry for every appearance it
/// was drawn for, where the one without an `appearances` key is the default the
/// light appearance uses.
private struct ColorSet: Decodable {
    let colors: [ColorEntry]

    /// The universal entry carrying no appearance — the watch entry is also
    /// appearance-less, so the idiom is what tells them apart.
    var light: ColorEntry? {
        colors.first { $0.appearances == nil && $0.idiom == "universal" }
    }

    var dark: ColorEntry? {
        colors.first { $0.appearances?.contains(CatalogueAppearance(value: "dark")) == true }
    }

    var watch: ColorEntry? {
        colors.first { $0.idiom == "watch" }
    }

    /// Whichever entry the platform would resolve for that surface.
    subscript(appearance: Appearance) -> ColorEntry? {
        switch appearance {
        case .light: light
        case .dark: dark
        case .watch: watch
        }
    }

    /// `ios/`, reached from this file rather than from `Bundle.module` — the
    /// test bundle's copy is a build-system artefact whose shape differs between
    /// SwiftPM and Xcode, and the sources do not.
    private static let iosDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // OndUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // OndCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios

    static let palette = iosDirectory
        .appending(path: "Packages/OndCore/Sources/OndUI/Colors.xcassets")
    static let appCatalogue = iosDirectory.appending(path: "Ond/Assets.xcassets")

    /// Nil when no colourset is filed under that name.
    init?(at catalogue: URL, named name: String) throws {
        let url = catalogue.appending(path: "\(name).colorset/Contents.json")
        guard let data = try? Data(contentsOf: url) else { return nil }

        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// Every colourset in a catalogue, by the name code refers to it as — for a
    /// namespaced group, the directory is part of that name.
    static func namesInCatalogue(at catalogue: URL) throws -> Set<String> {
        let files = FileManager.default
        let groups = try files.contentsOfDirectory(at: catalogue, includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)

        let names = try groups.flatMap { group in
            try files.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "colorset" }
                .map { $0.deletingPathExtension().pathComponents.suffix(2).joined(separator: "/") }
        }
        return Set(names)
    }
}

private struct ColorEntry: Decodable, Equatable {
    let appearances: [CatalogueAppearance]?
    let idiom: String
    let color: CatalogueColor
}

private struct CatalogueAppearance: Decodable, Equatable {
    let value: String
}

private struct CatalogueColor: Decodable, Equatable {
    /// Left as strings: a catalogue writes a component as `"0x6E"` or `"0.431"`
    /// interchangeably, and equality between two entries is a string compare.
    let components: [String: String]

    /// WCAG 2.1 contrast, `(lighter + 0.05) / (darker + 0.05)`. Nil where either
    /// colour has a component this cannot read, which a `#require` turns into a
    /// failure rather than a silently passing comparison.
    func contrast(against other: CatalogueColor) -> Double? {
        guard let mine = relativeLuminance, let theirs = other.relativeLuminance else { return nil }

        return (max(mine, theirs) + 0.05) / (min(mine, theirs) + 0.05)
    }

    /// This colour at `alpha` over `ground`, as the colour a person actually
    /// sees. SwiftUI composites `.opacity` in the display's space, so the blend
    /// is on the stored components rather than on linearised ones.
    func blended(over ground: CatalogueColor, alpha: Double) -> CatalogueColor? {
        var mixed: [String: String] = [:]

        for name in ["red", "green", "blue"] {
            guard let mine = channel(name), let theirs = ground.channel(name) else { return nil }
            mixed[name] = String(mine * alpha + theirs * (1 - alpha))
        }
        return CatalogueColor(components: mixed)
    }

    /// WCAG relative luminance. Every colourset in this palette declares
    /// `"color-space": "srgb"`, which is what makes the transfer function below
    /// the right one.
    private var relativeLuminance: Double? {
        guard
            let red = channel("red"),
            let green = channel("green"),
            let blue = channel("blue")
        else { return nil }

        return 0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// One channel as 0...1, from the `"0x6E"` form every colourset in both
    /// catalogues is written in, or the decimal a blend produces.
    private func channel(_ name: String) -> Double? {
        guard let raw = components[name] else { return nil }

        guard raw.hasPrefix("0x") else { return Double(raw) }

        return Int(raw.dropFirst(2), radix: 16).map { Double($0) / 255 }
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
