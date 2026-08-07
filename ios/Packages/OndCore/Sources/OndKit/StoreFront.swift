import Foundation

/// One of the subscriptions this app sells, in the vocabulary of the app rather
/// than of `StoreKit`.
///
/// Only what a paywall draws. The `Product` type carries a dozen more fields —
/// subscription group, promotional offers, introductory periods — and every one
/// of them would be a reason for a view to reach past this boundary.
public struct SubscriptionProduct: Sendable, Equatable {
    /// Which tier buying this grants. Never `.free`.
    public let tier: SubscriptionTier

    /// Already formatted for the storefront the person is buying from. Never
    /// composed here: the App Store owns the currency, the symbol's position,
    /// and whether the amount rounds — and it varies by country.
    public let displayPrice: String

    public init(tier: SubscriptionTier, displayPrice: String) {
        self.tier = tier
        self.displayPrice = displayPrice
    }
}

/// One `StoreKit` transaction, reduced to what this app decides from.
///
/// The JWS travels alongside the decoded fields rather than instead of them:
/// this device reads the fields to decide what to show, and the server reads the
/// JWS to decide what to spend. Neither trusts the other's reading, which is the
/// whole arrangement.
public struct SubscriptionTransaction: Sendable, Equatable {
    public let id: UInt64
    public let productID: String

    /// When the current period ends. `nil` for a product that does not expire,
    /// which this app does not sell — treated as "no expiry" rather than
    /// rejected, because a rule that silently dropped a transaction would be
    /// invisible.
    public let expirationDate: Date?

    /// Set when Apple refunded or revoked the purchase. Present here at all
    /// because `Transaction.updates` delivers revocations, and a client that
    /// filtered them out would leave the server honouring a refund forever.
    public let revocationDate: Date?

    /// `Transaction.jwsRepresentation`, verbatim, for the server to verify.
    public let jws: String

    public init(
        id: UInt64,
        productID: String,
        expirationDate: Date?,
        revocationDate: Date?,
        jws: String
    ) {
        self.id = id
        self.productID = productID
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.jws = jws
    }

    /// What this transaction entitles somebody to at `moment`, which is `.free`
    /// for anything spent, refunded, or bought from a price list this build does
    /// not know.
    ///
    /// `Transaction.currentEntitlements` has already applied most of this, so
    /// the checks look redundant — they are not. This is the rule the app gates
    /// on, and a rule that lives only inside a framework is one no test can
    /// state and no reader can find.
    public func entitledTier(at moment: Date) -> SubscriptionTier {
        guard revocationDate == nil,
              let tier = SubscriptionTier.tier(forProductIdentifier: productID)
        else {
            return .free
        }

        guard let expirationDate else { return tier }

        return expirationDate > moment ? tier : .free
    }

    /// What the submission ledger records.
    ///
    /// The revocation is part of the key, not just the id: a refund arrives as
    /// the *same* transaction with a date on it, and a ledger keyed on the id
    /// alone would skip it as already sent — leaving the server paying out a
    /// subscription Apple has refunded.
    public var submissionKey: String {
        revocationDate == nil ? "\(id)" : "\(id).revoked"
    }
}

/// How a purchase attempt ended.
///
/// `pending` is a real outcome rather than a failure: Ask to Buy sends the
/// request to a parent and the answer arrives hours later, through
/// `StoreFront/updates()`, which is exactly why that stream exists.
public enum PurchaseOutcome: Sendable, Equatable {
    case purchased(SubscriptionTransaction)
    case cancelled
    case pending
}

public enum StoreFrontError: LocalizedError, Equatable {
    /// The App Store has no such product. In the simulator this means the run
    /// scheme is not pointed at `Ond.storekit`; on a device it means the
    /// product is not yet approved in App Store Connect.
    case productUnavailable

    /// `StoreKit` declined to vouch for the signature on a transaction it just
    /// produced. Surfaced rather than swallowed: it should never happen, and a
    /// silent "purchase did nothing" is the worst possible way to find out.
    case unverified

    /// Without this conformance `localizedDescription` bridges to a bare
    /// `NSError`, so the log line that records a failed purchase says "The
    /// operation couldn't be completed" and names neither case.
    public var errorDescription: String? {
        switch self {
        case .productUnavailable: "the App Store has no such product"
        case .unverified: "StoreKit would not verify the transaction"
        }
    }
}

/// Everything this app needs from `StoreKit`, and nothing else.
///
/// A seam for the same reason `assistant::ModelClient` is one on the server: the
/// interesting logic is what the app *decides* from a set of transactions, and
/// none of that should need a signed-in App Store account and a booted simulator
/// to exercise. `StoreKitStoreFront` is the only type in the repository that
/// imports `StoreKit`.
public protocol StoreFront: Sendable {
    /// Both subscriptions, for the prices on the paywall. Empty rather than
    /// throwing — the paywall has a story for a missing price, and a person with
    /// no signal should still be able to read what each tier is.
    func products() async -> [SubscriptionProduct]

    /// What `StoreKit` currently considers this person entitled to. Answered
    /// from the device, so it works offline, which is why no screen ever waits
    /// on the server for this.
    func currentEntitlements() async -> [SubscriptionTransaction]

    /// Transactions arriving after launch: a renewal, a purchase made on
    /// another device, an Ask to Buy approval, a refund, or the crossgrade
    /// Apple issues when somebody moves between the two tiers.
    func updates() -> AsyncStream<SubscriptionTransaction>

    /// Buys `tier`.
    ///
    /// Buying one while holding the other is an ordinary upgrade or downgrade
    /// rather than a second subscription, because both products sit in one App
    /// Store subscription group: Apple prorates it, cancels the old one, and
    /// issues a fresh transaction naming the new product. Nothing here has to
    /// know that beyond passing the tier through.
    func purchase(_ tier: SubscriptionTier) async throws -> PurchaseOutcome

    /// Restores purchases, which App Review requires a paywall to offer. It
    /// prompts for the App Store password, so it is only ever called from a
    /// button somebody pressed.
    func restore() async throws
}
