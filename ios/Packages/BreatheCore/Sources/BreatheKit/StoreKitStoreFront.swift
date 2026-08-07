import Foundation
import StoreKit

/// The only type in the repository that imports `StoreKit`.
///
/// Everything above it works in `SubscriptionTransaction` values, which is what lets the
/// tier rules and the submission ledger be tested on the host with no App Store
/// account, no booted simulator, and no purchase.
///
/// Stateless, and therefore a struct. Holding the resolved `Product`s between
/// the paywall's prices and the same screen's purchase looks worth doing, and is
/// not: it makes this an actor, and an actor's isolated members cannot satisfy a
/// `Sendable` protocol under Swift 6 without a conformance the compiler refuses.
/// `StoreKit` caches product metadata on the device anyway, so the second lookup
/// is a local read rather than the round trip it appears to be.
public struct StoreKitStoreFront: StoreFront {
    public init() {}

    public func products() async -> [SubscriptionProduct] {
        await resolve(SubscriptionTier.purchasable.compactMap(\.productIdentifier))
            .compactMap { product in
                SubscriptionTier.tier(forProductIdentifier: product.id).map {
                    SubscriptionProduct(tier: $0, displayPrice: product.displayPrice)
                }
            }
            // Cheapest tier first, from the ladder rather than from whatever
            // order the App Store answered in.
            .sorted { $0.tier < $1.tier }
    }

    public func currentEntitlements() async -> [SubscriptionTransaction] {
        var entitlements: [SubscriptionTransaction] = []
        for await result in Transaction.currentEntitlements {
            if let transaction = SubscriptionTransaction(result) {
                entitlements.append(transaction)
            }
        }

        return entitlements
    }

    public func updates() -> AsyncStream<SubscriptionTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    // Finished whatever it turned out to say, and before the
                    // yield. An unfinished transaction is redelivered on every
                    // launch for the life of the install, and the entitlement it
                    // grants is durable without it — `currentEntitlements` still
                    // reports it, and the server's own retry is this app's
                    // ledger rather than StoreKit's queue.
                    await result.unsafePayloadValue.finish()

                    if let transaction = SubscriptionTransaction(result) {
                        continuation.yield(transaction)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func purchase(_ tier: SubscriptionTier) async throws -> PurchaseOutcome {
        guard let identifier = tier.productIdentifier,
              let product = await resolve([identifier]).first
        else {
            throw StoreFrontError.productUnavailable
        }

        switch try await product.purchase() {
        case let .success(result):
            await result.unsafePayloadValue.finish()
            guard let transaction = SubscriptionTransaction(result) else {
                throw StoreFrontError.unverified
            }
            return .purchased(transaction)
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        // StoreKit's result enum is not frozen, and a case added in a later
        // OS must not stop this compiling. Read as "nothing was bought",
        // which is the only assumption that cannot wrongly entitle anybody.
        @unknown default:
            return .cancelled
        }
    }

    public func restore() async throws {
        try await AppStore.sync()
    }

    /// Asks the App Store for exactly what the caller needs — both products for
    /// the paywall's prices, one for the purchase somebody is waiting on.
    private func resolve(_ identifiers: [String]) async -> [Product] {
        await (try? Product.products(for: identifiers)) ?? []
    }
}

private extension SubscriptionTransaction {
    /// `nil` for a transaction `StoreKit` will not vouch for.
    ///
    /// Dropped rather than passed along unverified: the signature is the only
    /// thing separating a real purchase from a tampered one, and this app's
    /// answer to a failed check is the same as the server's — it entitles
    /// nobody.
    init?(_ result: VerificationResult<StoreKit.Transaction>) {
        guard case let .verified(transaction) = result else { return nil }

        self.init(
            id: transaction.id,
            productID: transaction.productID,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            jws: result.jwsRepresentation
        )
    }
}
