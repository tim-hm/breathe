import SwiftUI

/// The visual language, in one place.
///
/// Deliberately holds no domain types — this package knows nothing about
/// techniques or goals. Mapping a domain value to an accent is the feature's
/// job, which keeps the dependency pointing one way (docs/code-structure.md).
public enum Theme {
    /// A four-step scale. Constraining spacing to four values is what keeps a
    /// minimal interface looking deliberate rather than merely sparse.
    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let close: CGFloat = 8
        public static let standard: CGFloat = 16
        public static let loose: CGFloat = 24
    }

    /// Accents, named for the feeling rather than the colour, so a palette
    /// change is a one-line edit here instead of a search across views.
    public enum Accent {
        /// Cool blue — settling.
        public static let settle = Color(red: 0.36, green: 0.55, blue: 0.75)
        /// Deep indigo — night.
        public static let night = Color(red: 0.35, green: 0.36, blue: 0.61)
        /// Warm amber — activating.
        public static let spark = Color(red: 0.85, green: 0.60, blue: 0.28)
        /// Muted green — recovery.
        public static let restore = Color(red: 0.40, green: 0.64, blue: 0.51)
    }
}
