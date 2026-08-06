@testable import BreatheUI
import Foundation
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

/// One `.colorset` as a catalogue stores it: an entry for every appearance it
/// was drawn for, where the one without an `appearances` key is the default the
/// light appearance uses.
private struct ColorSet: Decodable {
    let colors: [ColorEntry]

    var light: ColorEntry? {
        colors.first { $0.appearances == nil }
    }

    var dark: ColorEntry? {
        colors.first { $0.appearances?.contains(CatalogueAppearance(value: "dark")) == true }
    }

    /// `ios/`, reached from this file rather than from `Bundle.module` — the
    /// test bundle's copy is a build-system artefact whose shape differs between
    /// SwiftPM and Xcode, and the sources do not.
    private static let iosDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BreatheUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // BreatheCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios

    static let palette = iosDirectory
        .appending(path: "Packages/BreatheCore/Sources/BreatheUI/Colors.xcassets")
    static let appCatalogue = iosDirectory.appending(path: "Breathe/Assets.xcassets")

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
    let color: CatalogueColor
}

private struct CatalogueAppearance: Decodable, Equatable {
    let value: String
}

private struct CatalogueColor: Decodable, Equatable {
    /// Left as strings: a catalogue writes a component as `"0x6E"` or `"0.431"`
    /// interchangeably, and this only ever compares them.
    let components: [String: String]
}
