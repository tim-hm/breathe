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
public final class PlusStore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
        category: "plus"
    )

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
    public private(set) var products: [PlusProduct] = []

    /// Whether a purchase or a restore is in flight, for the buttons to disable
    /// themselves with. One flag for all of them: they are the same modal moment
    /// as far as the screen is concerned, and none can start while another is
    /// running.
    public private(set) var isBusy = false

    /// Set when a purchase went to Ask to Buy. The answer arrives later through
    /// `updates`, so the paywall says so rather than looking as though the
    /// button did nothing.
    public private(set) var isAwaitingApproval = false

    /// The catalogue gate. Reads as a sentence at the call site, and keeps the
    /// comparison — rather than an equality that would lock a Coach subscriber
    /// out of what Plus buys — in one place.
    public var isPlus: Bool {
        tier >= .plus
    }

    /// The assistant gate, mirrored from the server. The server enforces it;
    /// this only decides whether to offer the upgrade.
    public var isCoach: Bool {
        tier >= .coach
    }

    private let front: any PlusStoreFront
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
        front: any PlusStoreFront,
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
        guard products.isEmpty else { return }

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
        guard !isBusy else { return }
        isBusy = true
        isAwaitingApproval = false
        defer { isBusy = false }

        do {
            switch try await front.purchase(tier) {
            case let .purchased(transaction):
                await submit(transaction)
                await refresh()
            case .pending:
                isAwaitingApproval = true
            case .cancelled:
                break
            }
        } catch {
            // Not surfaced. Every failure here is either the person's own
            // cancellation dressed differently or an App Store outage, and a
            // paywall that shows a technical error has already lost the sale it
            // was there for.
            Self.logger.notice("purchase failed: \(error.localizedDescription)")
        }
    }

    /// Restores an existing subscription, which App Review requires every
    /// paywall to offer.
    ///
    /// It prompts for an App Store password, so it runs only from a button.
    public func restore() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await front.restore()
        } catch {
            Self.logger.notice("restore failed: \(error.localizedDescription)")
        }

        // Regardless of the outcome: `AppStore.sync()` throws when the person
        // dismisses the password prompt, and the entitlement may still have
        // arrived through `updates` while it was open.
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
    private func submit(_ transaction: PlusTransaction) async {
        guard !submitted.contains(transaction.submissionKey) else { return }

        do {
            try await entitlements.submit(transaction.jws)
            submitted.insert(transaction.submissionKey)
        } catch {
            Self.logger.notice("entitlement sync deferred: \(error.localizedDescription)")
        }
    }
}
