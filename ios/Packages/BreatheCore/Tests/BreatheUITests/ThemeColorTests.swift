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
    @Test("every token names a colourset in the catalogue", arguments: ColorToken.allCases)
    func tokenHasAColorSet(_ token: ColorToken) throws {
        _ = try #require(
            try ColorSet(token: token),
            "\(token.rawValue) is missing from Colors.xcassets"
        )
    }

    /// A colourset with one entry is one somebody forgot to theme. Every colour
    /// in this palette is tuned per appearance, so a single entry — or two
    /// identical ones — is a mistake rather than a choice.
    @Test("every token carries its own dark value", arguments: ColorToken.allCases)
    func tokenAdaptsToAppearance(_ token: ColorToken) throws {
        let colorSet = try #require(try ColorSet(token: token))

        #expect(colorSet.dark != nil, "\(token.rawValue) has no dark entry")
        #expect(
            colorSet.dark != colorSet.light,
            "\(token.rawValue) is the same in both appearances"
        )
    }

    /// The other direction: a colourset nothing names is dead weight at best,
    /// and at worst the survivor of a rename that left the token pointing at
    /// nothing.
    @Test("every colourset in the catalogue is named by a token")
    func catalogueHasNoOrphans() {
        let named = Set(ColorToken.allCases.map(\.rawValue))

        let enumerator = FileManager.default.enumerator(
            at: ColorSet.catalogue,
            includingPropertiesForKeys: nil
        )
        let colorSets = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "colorset" }
            // "…/Accent/Brand.colorset" is the token "Accent/Brand": the group
            // directory is a namespace in the catalogue and part of the name.
            .map {
                "\($0.deletingLastPathComponent().lastPathComponent)/\($0.deletingPathExtension().lastPathComponent)"
            }

        #expect(!colorSets.isEmpty)
        #expect(Set(colorSets).subtracting(named).isEmpty)
    }
}

/// One `.colorset` as the catalogue stores it: an entry for every appearance it
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

    /// The catalogue in the source tree, reached from this file rather than from
    /// `Bundle.module` — the test bundle's copy is a build-system artefact whose
    /// shape differs between SwiftPM and Xcode, and the sources do not.
    static let catalogue = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BreatheUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // BreatheCore
        .appending(path: "Sources/BreatheUI/Colors.xcassets")

    /// Nil when no colourset is filed under the token's name.
    init?(token: ColorToken) throws {
        let url = Self.catalogue.appending(path: "\(token.rawValue).colorset/Contents.json")
        guard let data = try? Data(contentsOf: url) else { return nil }

        self = try JSONDecoder().decode(Self.self, from: data)
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
    /// Left as strings: the catalogue writes a component as `"0x6E"` or
    /// `"0.431"` interchangeably, and this only ever compares them.
    let components: [String: String]
}
