import Foundation
import os

/// Which tier this person is on, and the only thing any screen asks.
///
/// Offline-first, in the strict sense: the tier is answered from `StoreKit` on
/// this device, which works with no signal, and the server submission is a sync
/// that runs alongside — never a gate in front of it. Somebody who subscribes on
/// a train has their subscription on that train.
///
/// The two halves are deliberately asymmetric, because they answer different
/// questions. This device decides what to *show* — which techniques open, which
/// upsell appears — and none of that costs anything to give away, because a
/// session runs here. The server decides what to *spend* on the language model,
/// and it will not take this app's word for it.
///
/// Nothing here reports a sync failure to a view: there is no action the person
/// could take, and the only consequence is the assistant answering from its
/// rules until the next launch retries.
@MainActor
@Observable
public final class SubscriptionStore: PersonalStore {
    private static let logger = Logger(category: "subscription")

    /// The key keeps its old spelling on purpose: it names a value already
    /// written to disk on installed builds, and renaming it would silently drop
    /// every existing subscriber back to free for one launch.
    private static let tierKey = "plus.tier"

    /// What this person is entitled to right now.
    ///
    /// Written through to `UserDefaults` on every change and read back at init,
    /// so a launch shows the right thing on the first frame. Without the cache
    /// every launch would render the free state for as long as `StoreKit` took
    /// to answer, which a subscriber would experience as their catalogue
    /// re-locking itself at every cold start.
    ///
    /// Guarded on a genuine change, because `refresh` assigns unconditionally
    /// and runs on every foreground: Swift fires `didSet` on an equal-value
    /// assignment, so without it the defaults plist is dirtied for a value that
    /// changes about once a month.
    public private(set) var tier: SubscriptionTier {
        didSet {
            guard oldValue != tier else { return }

            defaults.set(tier.rawValue, forKey: Self.tierKey)
        }
    }

    /// The subscriptions on offer, cheapest first, once the App Store has said
    /// what they cost.
    public private(set) var products: [SubscriptionProduct] = []

    /// How far a purchase or a restore has got.
    ///
    /// One enum rather than the pair of flags it replaces, which is what every
    /// other observable model here does and for the same reason: two booleans
    /// admit four states, and "busy while awaiting approval" is not one of them.
    /// A third condition would otherwise be a third flag and eight.
    public enum PurchaseState: Sendable, Equatable {
        case idle
        /// A purchase or a restore is in flight, and no second one may start.
        case working
        /// The purchase went to Ask to Buy. The answer arrives later through
        /// `updates`, so this is where it rests rather than a step on the way
        /// back to `idle` — the buttons come back to life while somebody else
        /// decides.
        case awaitingApproval
    }

    public private(set) var purchaseState: PurchaseState = .idle

    /// Whether a button should refuse to start anything, which is the only
    /// question the paywall asks of `purchaseState`. Deliberately false while an
    /// Ask to Buy is outstanding: that answer is somewhere else, and the buttons
    /// have no reason to stay dead waiting for it.
    public var isBusy: Bool {
        purchaseState == .working
    }

    /// Whether a purchase went to Ask to Buy, so the paywall says so rather than
    /// looking as though the button did nothing.
    public var isAwaitingApproval: Bool {
        purchaseState == .awaitingApproval
    }

    private let front: any StoreFront
    private let entitlements: any EntitlementSyncing
    private let defaults: UserDefaults

    /// Transactions the server has accepted during this run.
    ///
    /// In memory, not on disk, and that is the retry policy: one submission per
    /// transaction per launch. Persisting it would save a request on the launches
    /// after the first and cost the ability to ever re-sync — a server row lost
    /// or restored from a backup would never be told about a purchase again,
    /// because this device would have recorded it as done. The RPC is idempotent
    /// precisely so the cheap answer is the safe one.
    private var submitted: Set<String> = []

    public init(
        front: any StoreFront,
        entitlements: any EntitlementSyncing,
        defaults: UserDefaults = .standard
    ) {
        self.front = front
        self.entitlements = entitlements
        self.defaults = defaults
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read. An unreadable or
        // unknown stored value reads as free — the safe direction, and the one
        // a single refresh corrects.
        tier = SubscriptionTier(rawValue: defaults.integer(forKey: Self.tierKey)) ?? .free
    }

    /// Reads what `StoreKit` already knows, then keeps listening for the rest of
    /// the process's life.
    ///
    /// Does not return until the stream ends, so it belongs in a `.task` rather
    /// than being awaited on a path something else is waiting for. The initial
    /// read happens first, so one call covers both the launch state and every
    /// later change.
    public func watch() async {
        await refresh()

        for await transaction in front.updates() {
            // Submitted directly rather than only through `refresh`, because a
            // revocation is the one thing that arrives here and is *absent*
            // from `currentEntitlements` — leaving it unsent would have the
            // server honour a refund until the subscription's original expiry.
            await submit(transaction)
            await refresh()
        }
    }

    /// Re-reads the entitlement and pushes anything the server has not seen.
    ///
    /// Safe on every foreground: with nothing outstanding it is one local
    /// `StoreKit` read and no network at all. Deliberately does not fetch the
    /// prices — that is an App Store round trip, and it is only the paywall that
    /// needs them.
    ///
    /// The tier is the *highest* of whatever `StoreKit` reports rather than the
    /// first. One subscription group means one active subscription in practice,
    /// but a crossgrade can leave both visible for a moment, and the answer
    /// during that moment should be the one the person is paying for.
    public func refresh() async {
        let entitlements = await front.currentEntitlements()
        let now = Date()

        tier = entitlements
            .map { $0.entitledTier(at: now) }
            .max() ?? .free

        for transaction in entitlements {
            await submit(transaction)
        }
    }

    /// Fetches the prices, for a screen that is about to show them.
    ///
    /// Separate from [`refresh`] because it is the one part of this store that
    /// talks to the App Store: folding it in would put a network fetch on every
    /// cold launch for the majority of people who never open the paywall. Cached
    /// after the first success, so reopening the sheet is free.
    public func loadProducts() async {
        // Counted rather than emptiness-checked: the App Store can answer with
        // one of the two, and latching on that would leave the other tier
        // priceless for the life of the process.
        guard products.count < SubscriptionTier.purchasable.count else { return }

        products = await front.products()
    }

    /// Buys `tier`.
    ///
    /// Buying Coach while holding Plus is an upgrade, not a second
    /// subscription — both products are in one App Store subscription group, so
    /// Apple prorates the remainder, cancels the old one, and delivers a fresh
    /// transaction. The entitlement is then applied from `StoreKit`'s answer
    /// rather than from the server's, so the screen changes the moment the sheet
    /// dismisses.
    public func purchase(_ tier: SubscriptionTier) async {
        guard purchaseState != .working else { return }
        purchaseState = .working

        do {
            switch try await front.purchase(tier) {
            case let .purchased(transaction):
                await submit(transaction)
                await refresh()
                purchaseState = .idle
            case .pending:
                purchaseState = .awaitingApproval
            case .cancelled:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .idle
            // Not surfaced. Every failure here is either the person's own
            // cancellation dressed differently or an App Store outage, and a
            // paywall that shows a technical error has already lost the sale it
            // was there for.
            Self.logger.notice("purchase failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restores an existing subscription, which App Review requires every
    /// paywall to offer.
    ///
    /// It prompts for an App Store password, so it runs only from a button.
    public func restore() async {
        guard purchaseState != .working else { return }
        // Restored to what it was rather than to idle: a restore run while an
        // Ask to Buy is still outstanding must not clear the notice that
        // explains why nothing has happened yet.
        let resting = purchaseState
        purchaseState = .working
        defer { purchaseState = resting }

        do {
            try await front.restore()
        } catch {
            Self.logger.notice("restore failed: \(error.localizedDescription, privacy: .public)")
        }

        // Regardless of the outcome: `AppStore.sync()` throws when the person
        // dismisses the password prompt, and the entitlement may still have
        // arrived through `updates` while it was open.
        await refresh()
    }

    /// Drops the cached tier and re-derives it, which is not the same as
    /// cancelling anything.
    ///
    /// Deleting an account does not end an App Store subscription — only Apple
    /// can, and the confirmation that leads here says so. So this is the one
    /// erasure that puts back what it took: the cached tier is a note about a
    /// person filed on this device and goes, while the entitlement it was a note
    /// *about* is a fact about their Apple ID and survives. Leaving the cache
    /// cleared would show a paying subscriber the free tier until something
    /// happened to refresh it, which is the app appearing to have cancelled a
    /// subscription it cannot cancel.
    ///
    /// Clearing `submitted` is what carries the subscription onto the new
    /// identity in this run rather than the next launch: the erased row took the
    /// binding with it, and the refresh below resubmits the transaction against
    /// no holder at all — exactly what a merge relies on.
    public func erase() async {
        tier = .free
        submitted.removeAll()
        defaults.removeObject(forKey: Self.tierKey)

        await refresh()
    }

    /// Tells the server about one transaction, at most once per launch.
    ///
    /// The ledger is what makes this callable on every foreground without
    /// turning into a request per foreground. A failure leaves the key
    /// unrecorded, so the next attempt tries again — the same
    /// retry-on-next-launch shape the profile sync uses, and for the same
    /// reason: a purchase that reaches the server a day late costs the person
    /// only a rule-based assistant in the meantime.
    private func submit(_ transaction: SubscriptionTransaction) async {
        guard !submitted.contains(transaction.submissionKey) else { return }

        do {
            try await entitlements.submit(transaction.jws)
            submitted.insert(transaction.submissionKey)
        } catch {
            Self.logger
                .notice(
                    "entitlement sync deferred: \(error.localizedDescription, privacy: .public)"
                )
        }
    }
}
