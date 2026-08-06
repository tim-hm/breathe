import SwiftUI

/// Every colour the design system ships, under the name it is filed as in
/// `Colors.xcassets`.
///
/// One list rather than a string literal beside each `Theme` constant, because
/// `Color(_:bundle:)` has no failing form: a name that no longer matches an
/// asset paints black at runtime and says nothing. `ThemeColorTests` walks these
/// cases against the catalogue on disk, so a renamed or deleted colour fails a
/// test instead of shipping as a black view.
enum ColorToken: String, CaseIterable {
    case surfaceGround = "Surface/Ground"
    case surfaceRaised = "Surface/Raised"
    case surfaceLine = "Surface/Line"

    case inkPrimary = "Ink/Primary"
    case inkSecondary = "Ink/Secondary"
    case inkTertiary = "Ink/Tertiary"

    case accentBrand = "Accent/Brand"
    case accentSettle = "Accent/Settle"
    case accentNight = "Accent/Night"
    case accentSpark = "Accent/Spark"
    case accentRestore = "Accent/Restore"
    case accentAttend = "Accent/Attend"
    case accentHold = "Accent/Hold"
    case accentCaution = "Accent/Caution"

    var color: Color {
        Color(rawValue, bundle: .module)
    }
}
