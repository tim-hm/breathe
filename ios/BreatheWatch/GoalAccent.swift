import BreatheKit
import BreatheUI
import SwiftUI

extension TechniqueGoal {
    /// The palette entry a goal is drawn in, matching the phone's mapping
    /// exactly — the same technique should be the same colour on both wrists
    /// and in the hand.
    ///
    /// Duplicated from the phone target rather than shared, because the only
    /// module both apps could hold it in is `BreatheUI`, and that module has no
    /// dependencies by design so the palette stays reusable and the domain
    /// never leaks into the design system. Twenty lines of mapping is the
    /// smaller price.
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
