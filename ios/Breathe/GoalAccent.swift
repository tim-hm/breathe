import BreatheKit
import BreatheUI
import SwiftUI

extension TechniqueGoal {
    /// The palette entry a goal is drawn in.
    ///
    /// App-local rather than inside either feature, because the catalogue and
    /// the session player both need it and neither owns it. It cannot live in
    /// `BreatheUI` at all: that module has no dependencies, so that a palette
    /// stays reusable and the domain never leaks into the design system.
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
