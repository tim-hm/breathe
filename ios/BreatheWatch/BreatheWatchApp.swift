import BreatheKit
import BreatheUI
import SwiftUI

/// The watch app's entry point.
///
/// A placeholder while M9's scaffolding lands. The features phase replaces this
/// body with the real composition root — the catalogue, the session engine, and
/// the extended runtime session the haptics need.
@main
struct BreatheWatchApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// The app name on the palette's ground, standing in for the wrist's home
/// screen until the catalogue arrives.
private struct PlaceholderView: View {
    /// Naming a domain type is the point rather than the content: it forces
    /// `BreatheKit`, and the Connect runtime behind it, to actually link on
    /// watchOS — which is what this scaffold exists to prove.
    private let goals = TechniqueGoal.allCases

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text("Breathe")
                .font(.title3)
                .foregroundStyle(Theme.Ink.primary)
            Text("\(goals.count) goals")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.ground)
    }
}
