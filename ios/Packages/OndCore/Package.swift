// swift-tools-version: 6.2
import PackageDescription

// One package, four targets — not four packages. SwiftPM offers no way to
// share a tools-version or a platform list across packages, so a split would
// mean maintaining those in triplicate and, worse, one `Package.resolved` per
// package: several lockfiles free to pin different versions of the same
// dependency, which is precisely what a lockfile exists to prevent.
//
// The module boundaries the split was for are enforced better here, by target
// dependencies — see the note on the OndAPI target.
let package = Package(
    name: "OndCore",
    // macOS is declared alongside iOS so `swift test` runs on the host in
    // seconds. Without it SwiftPM assumes macOS 10.13 and refuses to link
    // Connect, leaving a booted simulator as the only way to run a unit test —
    // which is not a dependency a decoding test should have.
    //
    // watchOS 26 is the floor that pairs with iOS 26 — the watch app ships
    // alongside the phone app, so the two move together rather than the wrist
    // dragging a lower floor into the shared targets. The floor sits at 26
    // because the phone's chrome is built on Liquid Glass — the minimising tab
    // bar — and an unreleased app has no installed base to strand by asking for
    // it unconditionally.
    //
    // The tools-version above is 6.2 for this line alone: `.v26` was not a
    // `SupportedPlatform` case before it, and the string form would trade a
    // checked constant for a literal nothing validates.
    //
    // macOS sits at 15 rather than 14 for one API: `Color.mix(with:by:)`, which
    // `OndStyle` uses to soften a goal accent into the exhale ink. Nothing runs
    // on macOS but the tests, and the floor only has to be low enough that a
    // host can build them — it is not a platform this ships to.
    platforms: [.iOS(.v26), .macOS(.v15), .watchOS(.v26)],
    products: [
        .library(name: "OndKit", targets: ["OndKit"]),
        .library(name: "OndUI", targets: ["OndUI"]),
        .library(name: "OndStyle", targets: ["OndStyle"]),
    ],
    dependencies: [
        // The Connect runtime. It speaks the Connect, gRPC, and gRPC-Web
        // protocols over URLSession; this app uses gRPC-Web, because that is
        // what tonic-web serves. See docs/transport.md.
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        // Declared directly even though connect-swift already depends on it:
        // the generated `.pb.swift` files `import SwiftProtobuf`, and a direct
        // import deserves a direct dependency rather than one that survives only
        // while connect-swift happens to keep it.
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
    ],
    targets: [
        // Deliberately a target and *not* a product. Only OndKit can reach
        // it, so the rule "app code never imports a generated protobuf type"
        // stops being a convention someone has to remember and becomes something
        // the compiler enforces — the app cannot name this module at all.
        .target(
            name: "OndAPI",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(name: "OndKit", dependencies: ["OndAPI"]),
        // No dependencies, ever. The design system stays free of domain types so
        // the palette stays reusable; mapping a `TechniqueGoal` onto an accent
        // belongs to OndStyle below, which may depend on both.
        //
        // The asset catalogue holds every colour, each with a light and a dark
        // value. Declaring it is what puts it in `Bundle.module` at all; without
        // this SwiftPM treats the directory as a stray file and every colour
        // resolves to nothing. Note that only Xcode compiles a catalogue with
        // actool — `swift build` copies it verbatim, which is why the palette's
        // test reads the JSON rather than resolving a `Color`.
        .target(name: "OndUI", resources: [.process("Colors.xcassets")]),
        // Mappings from a domain type onto a design token, and only those — no
        // views, which the two apps still write separately because a wrist is
        // not a small phone. `OndUI` must never learn what a `TechniqueGoal`
        // is, but that rule says nothing about a third module depending on both,
        // and a mapping written once per app target is one the phone and the
        // wrist are free to disagree about silently.
        .target(name: "OndStyle", dependencies: ["OndKit", "OndUI"]),
        // Decodes the committed catalogue.json — the Rust seed's field names,
        // which is a second way onto `Technique` and one no shipping binary
        // should have. A target and not a product, on the same terms as OndAPI:
        // the apps cannot name the module, so the rule is the compiler's rather
        // than a comment's.
        .target(name: "OndCatalogue", dependencies: ["OndKit"]),
        // Redraws the marketing site's figures from the same geometry the apps
        // draw. Also a target and not a product, so a development-time tool
        // cannot drift into a shipping binary. Run through
        // `mise run generate:diagrams`.
        .executableTarget(name: "OndDiagrams", dependencies: ["OndKit", "OndCatalogue"]),
        // Depends on OndAPI as well as OndKit because it builds proto
        // messages to feed the decoders. That is the boundary being tested, so
        // reaching across it here is the point rather than a leak.
        .testTarget(name: "OndKitTests", dependencies: ["OndKit", "OndAPI", "OndCatalogue"]),
        .testTarget(name: "OndUITests", dependencies: ["OndUI"]),
    ]
)
