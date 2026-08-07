@testable import BreatheKit
import Foundation
import Testing

/// A store front that answers from a script, so the tier rules and the
/// submission ledger are exercisable with no App Store account and no booted
/// simulator — which is the whole reason `PlusStoreFront` exists.
private final class FakeStoreFront: PlusStoreFront, @unchecked Sendable {
    private let lock = NSLock()
    private var entitlements: [PlusTransaction]
    private(set) var purchased: [SubscriptionTier] = []

    init(entitlements: [PlusTransaction] = []) {
        self.entitlements = entitlements
    }

    func set(_ entitlements: [PlusTransaction]) {
        lock.withLock { self.entitlements = entitlements }
    }

    func products() async -> [PlusProduct] {
        [
            PlusProduct(tier: .plus, displayPrice: "£0.99"),
            PlusProduct(tier: .coach, displayPrice: "£4.99"),
        ]
    }

    func currentEntitlements() async -> [PlusTransaction] {
        lock.withLock { entitlements }
    }

    func updates() -> AsyncStream<PlusTransaction> {
        AsyncStream { $0.finish() }
    }

    func purchase(_ tier: SubscriptionTier) async throws -> PlusPurchaseOutcome {
        lock.withLock { purchased.append(tier) }
        return .cancelled
    }

    func restore() async throws {}
}

/// Records every JWS it is handed, and fails on demand.
private final class RecordingEntitlements: EntitlementSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted: [String] = []
    private var shouldFail = false

    var received: [String] {
        lock.withLock { submitted }
    }

    func fail(_ failing: Bool) {
        lock.withLock { shouldFail = failing }
    }

    func submit(_ signedTransaction: String) async throws {
        let failing = lock.withLock { shouldFail }
        if failing {
            throw EntitlementRepositoryError.transport("scripted failure")
        }
        lock.withLock { submitted.append(signedTransaction) }
    }
}

private func transaction(
    id: UInt64 = 1,
    tier: SubscriptionTier = .plus,
    productID: String? = nil,
    expiresIn: TimeInterval? = 3600,
    revoked: Bool = false,
    jws: String = "jws"
) -> PlusTransaction {
    PlusTransaction(
        id: id,
        productID: productID ?? tier.productIdentifier ?? "",
        expirationDate: expiresIn.map { Date().addingTimeInterval($0) },
        revocationDate: revoked ? Date() : nil,
        jws: jws
    )
}

/// A `UserDefaults` nobody else shares, so one test cannot decide another's
/// starting state — the store caches its answer between launches on purpose.
private func scratchDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "plus.tests.\(UUID().uuidString)")
    return suite ?? .standard
}

@Suite("Subscription tiers")
struct SubscriptionTierTests {
    /// Every gate in the app is a comparison rather than an equality, so the
    /// ordering is load-bearing. A Coach subscriber must satisfy a Plus gate —
    /// getting this backwards would lock the catalogue for the people paying
    /// most for it.
    @Test("A higher tier satisfies a lower gate")
    func orderingIsALadder() {
        #expect(SubscriptionTier.coach > .plus)
        #expect(SubscriptionTier.plus > .free)
        #expect(SubscriptionTier.purchasable == [.plus, .coach])
    }

    /// The product ids are the one thing four separate places have to agree on
    /// — this file, the StoreKit configuration, the server's `PRODUCTS`, and App
    /// Store Connect — with nothing checking that they do. A round trip through
    /// the mapping is the only part of that this repository can pin.
    @Test("Each product id maps back to the tier it buys")
    func productIdentifiersRoundTrip() {
        for tier in SubscriptionTier.purchasable {
            let identifier = tier.productIdentifier
            #expect(identifier != nil)
            #expect(identifier.flatMap(SubscriptionTier.tier(forProductIdentifier:)) == tier)
        }

        #expect(SubscriptionTier.free.productIdentifier == nil)
        #expect(SubscriptionTier
            .tier(forProductIdentifier: "xyz.holmie.breathe.plus.yearly") == nil)
    }
}

@Suite("What a transaction entitles")
struct PlusTransactionTests {
    @Test("Each product entitles its own tier")
    func eachProductEntitlesItsTier() {
        let now = Date()

        #expect(transaction(tier: .plus).entitledTier(at: now) == .plus)
        #expect(transaction(tier: .coach).entitledTier(at: now) == .coach)
    }

    /// The expiry is the moment it ends, matching the server's own comparison.
    /// The two sides disagreeing by one instant would show somebody a subscriber
    /// catalogue while the assistant refused them the subscriber allowance.
    @Test("An expired subscription entitles nothing")
    func expiredEntitlesNothing() {
        let expiry = Date()
        let expired = PlusTransaction(
            id: 1,
            productID: SubscriptionTier.coach.productIdentifier ?? "",
            expirationDate: expiry,
            revocationDate: nil,
            jws: "jws"
        )

        #expect(expired.entitledTier(at: expiry) == .free)
        #expect(expired.entitledTier(at: expiry.addingTimeInterval(-1)) == .coach)
    }

    /// A refund ends the entitlement even though the period it paid for has not.
    @Test("A revoked subscription entitles nothing, however far off its expiry")
    func revokedEntitlesNothing() {
        let refunded = transaction(tier: .coach, expiresIn: 86400 * 365, revoked: true)

        #expect(refunded.entitledTier(at: Date()) == .free)
    }

    /// A receipt for a product this build does not sell — the withdrawn yearly
    /// Plus, or something a newer build introduced — must not be read as any
    /// tier at all.
    @Test("A product this build does not sell entitles nothing")
    func unknownProductEntitlesNothing() {
        let stale = transaction(productID: "xyz.holmie.breathe.plus.yearly")

        #expect(stale.entitledTier(at: Date()) == .free)
    }

    /// The refund case the ledger exists for: the same transaction arrives twice
    /// with different meanings, and a key that ignored the revocation would file
    /// the second one as already sent.
    @Test("A revocation is a different submission from the purchase it revokes")
    func revocationHasItsOwnLedgerKey() {
        #expect(transaction(id: 7).submissionKey != transaction(id: 7, revoked: true).submissionKey)
        #expect(transaction(id: 7).submissionKey == transaction(id: 7, jws: "other").submissionKey)
    }
}

@Suite("Plus store")
@MainActor
struct PlusStoreTests {
    /// The store reads the entitlement from the device and reports it without
    /// the server having said anything — the offline-first promise, stated as a
    /// test.
    @Test("A subscription on the device is live before any server call succeeds")
    func deviceEntitlementIsEnough() async {
        let front = FakeStoreFront(entitlements: [transaction(tier: .coach)])
        let server = RecordingEntitlements()
        server.fail(true)
        let store = PlusStore(front: front, entitlements: server, defaults: scratchDefaults())

        await store.refresh()

        #expect(store.tier == .coach)
        #expect(store.isPlus, "Coach contains Plus")
        #expect(store.isCoach)
        #expect(server.received.isEmpty)
    }

    /// A Plus subscriber gets the catalogue and not the assistant. This is the
    /// one place the two gates could be confused for each other, and confusing
    /// them either locks a payer out or gives the model away.
    @Test("Plus opens the catalogue and not the assistant")
    func plusIsNotCoach() async {
        let front = FakeStoreFront(entitlements: [transaction(tier: .plus)])
        let store = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: scratchDefaults()
        )

        await store.refresh()

        #expect(store.isPlus)
        #expect(!store.isCoach)
    }

    /// A crossgrade can leave both subscriptions momentarily visible, and the
    /// answer during that moment should be the one the person is paying for.
    @Test("Holding two entitlements resolves to the higher one")
    func theHigherEntitlementWins() async {
        let front = FakeStoreFront(entitlements: [
            transaction(id: 1, tier: .plus),
            transaction(id: 2, tier: .coach),
        ])
        let store = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: scratchDefaults()
        )

        await store.refresh()

        #expect(store.tier == .coach)
    }

    /// Every launch and every foreground calls `refresh`. Sending the same
    /// purchase each time would be a request per foreground for the life of the
    /// subscription.
    @Test("A transaction is submitted once, however often the store refreshes")
    func submissionHappensOnce() async {
        let front = FakeStoreFront(entitlements: [transaction(jws: "jws-plus")])
        let server = RecordingEntitlements()
        let store = PlusStore(front: front, entitlements: server, defaults: scratchDefaults())

        await store.refresh()
        await store.refresh()
        await store.refresh()

        #expect(server.received == ["jws-plus"])
    }

    /// A failed submission must not be recorded as done. This is the whole of
    /// the retry policy: the next attempt tries again because nothing was
    /// written.
    @Test("A failed submission is retried on the next refresh")
    func failedSubmissionIsRetried() async {
        let front = FakeStoreFront(entitlements: [transaction(jws: "jws-plus")])
        let server = RecordingEntitlements()
        server.fail(true)
        let store = PlusStore(front: front, entitlements: server, defaults: scratchDefaults())

        await store.refresh()
        #expect(server.received.isEmpty)

        server.fail(false)
        await store.refresh()
        #expect(server.received == ["jws-plus"])
    }

    /// The cache is what stops the catalogue re-locking itself on every cold
    /// launch, so it has to survive one — and it has to survive one in both
    /// directions. A cache that only ever went up would leave an ex-subscriber
    /// on Coach forever.
    @Test("The tier survives a launch, and so does losing it")
    func theTierSurvivesALaunch() async {
        let front = FakeStoreFront(entitlements: [transaction(tier: .coach)])
        let defaults = scratchDefaults()
        let store = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: defaults
        )

        await store.refresh()
        #expect(store.tier == .coach)
        #expect(relaunch(over: defaults, front: front).tier == .coach)

        front.set([])
        await store.refresh()
        #expect(store.tier == .free)
        #expect(relaunch(over: defaults, front: front).tier == .free)
    }

    /// A fresh store over the same defaults, which is what a cold launch is.
    private func relaunch(over defaults: UserDefaults, front: FakeStoreFront) -> PlusStore {
        PlusStore(front: front, entitlements: RecordingEntitlements(), defaults: defaults)
    }
}

@Suite("What a tier unlocks")
struct TechniqueGatingTests {
    private func technique(requires: SubscriptionTier) -> Technique {
        Technique(
            id: "t",
            slug: "t",
            name: "T",
            summary: "",
            goal: .calm,
            stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 1)],
            recommendedRounds: 1,
            requires: requires
        )
    }

    /// The gate is a comparison, so paying more never opens less.
    @Test("A locked technique opens at its tier and above")
    func lockedOpensAtItsTierAndAbove() {
        let locked = technique(requires: .plus)

        #expect(!locked.isUnlocked(for: .free))
        #expect(locked.isUnlocked(for: .plus))
        #expect(locked.isUnlocked(for: .coach))
    }

    /// The default is unlocked, matching the proto's zero value: a technique
    /// that arrives without the field — from an older server, or a truncated
    /// message — must not be one somebody is asked to pay for.
    @Test("A technique with nothing said about it is free")
    func theDefaultIsUnlocked() {
        #expect(technique(requires: .free).isUnlocked(for: .free))

        let unspecified = Technique(
            id: "t",
            slug: "t",
            name: "T",
            summary: "",
            goal: .calm,
            stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 1)],
            recommendedRounds: 1
        )
        #expect(unspecified.isUnlocked(for: .free))
    }
}
