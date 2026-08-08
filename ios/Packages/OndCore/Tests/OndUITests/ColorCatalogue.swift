import Foundation
import SwiftUI

/// The three surfaces the palette is drawn for, so every contrast question
/// `ThemeColorTests` asks is asked three times.
///
/// The watch is one of them rather than a copy of `dark` taken on trust:
/// `watchMirrorsTheDarkAppearance` is what makes the two agree today, and the
/// day a wrist entry is given a value of its own — the always-black screen is a
/// different rendering problem from a dark phone — the measurements have to
/// follow it there rather than keep reporting on the phone.
enum Appearance: String, CaseIterable {
    case light
    case dark
    case watch
}

/// One `.colorset` as a catalogue stores it: an entry for every appearance it
/// was drawn for, where the one without an `appearances` key is the default the
/// light appearance uses.
struct ColorSet: Decodable {
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

struct ColorEntry: Decodable, Equatable {
    let appearances: [CatalogueAppearance]?
    let idiom: String
    let color: CatalogueColor
}

struct CatalogueAppearance: Decodable, Equatable {
    let value: String
}

struct CatalogueColor: Decodable, Equatable {
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

    /// This colour pulled `fraction` of the way towards `ground`, as
    /// `Color.mix(with:by:)` pulls it.
    ///
    /// Through the real API rather than the arithmetic copy `blended` is, because
    /// the copy measures a colour the app never draws: `mix` interpolates
    /// perceptually unless told otherwise, so `Accent/Brand` softened over white
    /// resolves to `#629489` where the same fraction blended in sRGB gives
    /// `#61958b`. Close, and not the same — and the second one is what a hand
    /// calculation reaches for.
    ///
    /// Resolving against a default `EnvironmentValues` is sound here even though
    /// the host has no compiled catalogue: both colours are built from literal
    /// components, so nothing on this path resolves a name.
    func softened(towards ground: CatalogueColor, by fraction: Double) -> CatalogueColor? {
        guard let mine = color, let theirs = ground.color else { return nil }

        let mixed = mine.mix(with: theirs, by: fraction).resolve(in: EnvironmentValues())
        return CatalogueColor(components: [
            "red": String(mixed.red),
            "green": String(mixed.green),
            "blue": String(mixed.blue),
        ])
    }

    /// This entry as the `Color` the framework would mix, nil where a component
    /// is in a form `channel(_:)` cannot read.
    private var color: Color? {
        guard
            let red = channel("red"),
            let green = channel("green"),
            let blue = channel("blue")
        else { return nil }

        return Color(.sRGB, red: red, green: green, blue: blue)
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
