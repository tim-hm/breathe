// swift-tools-version: 6.0
import PackageDescription

// One package, four targets — not four packages. SwiftPM offers no way to
// share a tools-version or a platform list across packages, so a split would
// mean maintaining those in triplicate and, worse, one `Package.resolved` per
// package: several lockfiles free to pin different versions of the same
// dependency, which is precisely what a lockfile exists to prevent.
//
// The module boundaries the split was for are enforced better here, by target
// dependencies — see the note on the BreatheAPI target.
let package = Package(
    name: "BreatheCore",
    // macOS is declared alongside iOS so `swift test` runs on the host in
    // seconds. Without it SwiftPM assumes macOS 10.13 and refuses to link
    // Connect, leaving a booted simulator as the only way to run a unit test —
    // which is not a dependency a decoding test should have.
    //
    // watchOS 11 is the floor that pairs with iOS 18 — the watch app ships
    // alongside the phone app, so the two move together rather than the wrist
    // dragging a lower floor into the shared targets.
    platforms: [.iOS(.v18), .macOS(.v14), .watchOS(.v11)],
    products: [
        .library(name: "BreatheKit", targets: ["BreatheKit"]),
        .library(name: "BreatheUI", targets: ["BreatheUI"]),
        .library(name: "BreatheStyle", targets: ["BreatheStyle"]),
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
        // Deliberately a target and *not* a product. Only BreatheKit can reach
        // it, so the rule "app code never imports a generated protobuf type"
        // stops being a convention someone has to remember and becomes something
        // the compiler enforces — the app cannot name this module at all.
        .target(
            name: "BreatheAPI",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(name: "BreatheKit", dependencies: ["BreatheAPI"]),
        // No dependencies, ever. The design system stays free of domain types so
        // the palette stays reusable; mapping a `TechniqueGoal` onto an accent
        // belongs to BreatheStyle below, which may depend on both.
        //
        // The asset catalogue holds every colour, each with a light and a dark
        // value. Declaring it is what puts it in `Bundle.module` at all; without
        // this SwiftPM treats the directory as a stray file and every colour
        // resolves to nothing. Note that only Xcode compiles a catalogue with
        // actool — `swift build` copies it verbatim, which is why the palette's
        // test reads the JSON rather than resolving a `Color`.
        .target(name: "BreatheUI", resources: [.process("Colors.xcassets")]),
        // Mappings from a domain type onto a design token, and only those — no
        // views, which the two apps still write separately because a wrist is
        // not a small phone. `BreatheUI` must never learn what a `TechniqueGoal`
        // is, but that rule says nothing about a third module depending on both,
        // and a mapping written once per app target is one the phone and the
        // wrist are free to disagree about silently.
        .target(name: "BreatheStyle", dependencies: ["BreatheKit", "BreatheUI"]),
        // Depends on BreatheAPI as well as BreatheKit because it builds proto
        // messages to feed the decoders. That is the boundary being tested, so
        // reaching across it here is the point rather than a leak.
        .testTarget(name: "BreatheKitTests", dependencies: ["BreatheKit", "BreatheAPI"]),
        .testTarget(name: "BreatheUITests", dependencies: ["BreatheUI"]),
    ]
)
