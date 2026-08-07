import Foundation

/// What this person may use.
///
/// `Comparable`, and that is the type's job: every gate in the app reads
/// `tier >= .plus` rather than enumerating which tiers qualify, so a tier added
/// above `coach` changes no comparison anywhere. It mirrors `EntitlementTier` in
/// the proto and `Tier` on the server, and the three agree on the ordering
/// rather than on a shared representation.
///
/// The raw value is a stored key — the tier is cached across launches so the
/// first frame after a cold start shows the right thing — and it is written out
/// rather than synthesised so reordering the cases cannot silently promote
/// somebody.
public enum SubscriptionTier: Int, Sendable, Comparable, Codable, CaseIterable {
    /// The app, and the two techniques it opens with.
    case free = 0

    /// The full catalogue, and everything the app does that costs nothing per
    /// use.
    case plus = 1

    /// Plus, and the assistant backed by a language model.
    case coach = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The App Store product that buys this tier, or `nil` for the one nobody
    /// buys.
    ///
    /// These ids have to match `ios/Breathe/Breathe.storekit`, `PRODUCTS` in the
    /// server's `features/entitlement/verifier/appstore.rs`, and App Store
    /// Connect. Nothing checks that they agree at build time, and a mismatch
    /// presents as a paywall with no price and a purchase the server refuses.
    public var productIdentifier: String? {
        switch self {
        case .free: nil
        case .plus: "xyz.holmie.breathe.plus.monthly"
        case .coach: "xyz.holmie.breathe.coach.monthly"
        }
    }

    /// The tier a product id buys, or `nil` for one this build does not sell.
    ///
    /// `nil` rather than `.free`, because they are different facts: a product
    /// this app has never heard of is a transaction to ignore, not a person to
    /// downgrade. Whoever asks decides which of those it is.
    public static func tier(forProductIdentifier identifier: String) -> Self? {
        purchasable.first { $0.productIdentifier == identifier }
    }

    /// The tiers somebody can buy, cheapest first — the order a paywall lists
    /// them in, derived from the ladder rather than written out beside it.
    public static var purchasable: [Self] {
        allCases.filter { $0 > .free }.sorted()
    }
}
