import OndKit
import SwiftUI

extension View {
    /// Presents the paywall, opened on the tier that answers whatever the person
    /// just ran into.
    ///
    /// A modifier rather than a `.sheet` at each site: three screens offer a
    /// subscription — the catalogue, the detail screen, and the assistant's
    /// upsell — and three copies of the presentation are three chances to
    /// highlight the wrong tier or forget the sheet entirely.
    func paywall(highlighting tier: SubscriptionTier, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            PaywallView(highlighting: tier)
        }
    }
}

extension SubscriptionTier {
    /// What this tier is called in the interface.
    ///
    /// One mapping for the whole feature. The paywall's cards and the upsell's
    /// link used to answer this separately, which is how "Plus" and "önd Plus"
    /// end up on two screens describing the same thing.
    var title: String {
        switch self {
        case .free: "Free"
        case .plus: "Plus"
        case .coach: "Coach"
        }
    }

    /// The name as somebody would say it out loud, for a link or a button.
    var brandedTitle: String {
        self == .free ? "önd" : "önd \(title)"
    }
}
