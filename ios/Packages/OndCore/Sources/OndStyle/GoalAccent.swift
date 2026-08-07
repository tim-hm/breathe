import OndKit
import OndUI
import SwiftUI

public extension TechniqueGoal {
    /// The palette entry a goal is drawn in.
    ///
    /// One mapping, read by both apps, because a second copy of it fails
    /// silently: the same technique comes out a different colour on the wrist
    /// than in the hand, and nothing but a person's memory catches it.
    var accent: Color {
        switch self {
        case .calm: Theme.Accent.settle
        case .sleep: Theme.Accent.night
        case .energy: Theme.Accent.spark
        case .reset: Theme.Accent.restore
        case .focus: Theme.Accent.attend
        }
    }
}
