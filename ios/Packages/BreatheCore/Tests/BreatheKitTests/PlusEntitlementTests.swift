@testable import BreatheKit
import Foundation
import Testing

/// A store front that answers from a script, so the gating and the submission
/// ledger are exercisable with no App Store account and no booted simulator —
/// which is the whole reason `PlusStoreFront` exists.
private final class FakeStoreFront: PlusStoreFront, @unchecked Sendable {
    private let lock = NSLock()
    private var entitlements: [PlusTransaction]

    init(entitlements: [PlusTransaction] = []) {
        self.entitlements = entitlements
    }

    func set(_ entitlements: [PlusTransaction]) {
        lock.withLock { self.entitlements = entitlements }
    }

    func product() async -> PlusProduct? {
        PlusProduct(displayPrice: "£4.99")
    }

    func currentEntitlements() async -> [PlusTransaction] {
        lock.withLock { entitlements }
    }

    func updates() -> AsyncStream<PlusTransaction> {
        AsyncStream { $0.finish() }
    }

    func purchase() async throws -> PlusPurchaseOutcome {
        .cancelled
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
    productID: String = PlusProduct.identifier,
    expiresIn: TimeInterval? = 3600,
    revoked: Bool = false,
    jws: String = "jws"
) -> PlusTransaction {
    PlusTransaction(
        id: id,
        productID: productID,
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

@Suite("Plus entitlement")
struct PlusEntitlementTests {
    @Test("A current subscription entitles Plus")
    func currentSubscriptionEntitles() {
        #expect(transaction().entitlesPlus(at: Date()))
    }

    /// The expiry is the moment it ends, matching the server's own comparison.
    /// The two sides disagreeing by one instant would show somebody Plus copy
    /// while the assistant refused them the Plus allowance.
    @Test("An expired subscription does not")
    func expiredDoesNot() {
        let expiry = Date()
        let expired = PlusTransaction(
            id: 1,
            productID: PlusProduct.identifier,
            expirationDate: expiry,
            revocationDate: nil,
            jws: "jws"
        )

        #expect(!expired.entitlesPlus(at: expiry))
        #expect(expired.entitlesPlus(at: expiry.addingTimeInterval(-1)))
    }

    /// A refund ends the entitlement even though the period it paid for has
    /// not.
    @Test("A revoked subscription does not, however far off its expiry")
    func revokedDoesNot() {
        #expect(!transaction(expiresIn: 86400 * 365, revoked: true).entitlesPlus(at: Date()))
    }

    /// The catalogue may one day sell something else. A transaction for another
    /// product must not open the assistant, which is what the product-id check
    /// is for — `currentEntitlements` returns everything this app sells, not
    /// only this one.
    @Test("Another product does not entitle Plus")
    func anotherProductDoesNot() {
        #expect(!transaction(productID: "xyz.holmie.breathe.other").entitlesPlus(at: Date()))
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
    @Test("A subscription on the device is Plus before any server call succeeds")
    func deviceEntitlementIsEnough() async {
        let front = FakeStoreFront(entitlements: [transaction()])
        let server = RecordingEntitlements()
        server.fail(true)
        let store = PlusStore(front: front, entitlements: server, defaults: scratchDefaults())

        await store.refresh()

        #expect(store.isPlus)
        #expect(server.received.isEmpty)
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
    /// the retry policy: the next launch tries again because nothing was
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

    /// A lapsed subscription drops the person back to free without anything
    /// having run in between, and the cached flag must follow — a cache that
    /// only ever turned on would leave an ex-subscriber on Plus forever.
    @Test("A lapse takes Plus away again")
    func lapseRemovesPlus() async {
        let front = FakeStoreFront(entitlements: [transaction()])
        let defaults = scratchDefaults()
        let store = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: defaults
        )

        await store.refresh()
        #expect(store.isPlus)

        front.set([])
        await store.refresh()
        #expect(!store.isPlus)

        // And the next launch starts where this one left off, rather than
        // showing Plus for as long as StoreKit takes to answer.
        let relaunched = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: defaults
        )
        #expect(!relaunched.isPlus)
    }

    /// The cache is what stops the paywall flashing at a subscriber on every
    /// cold launch, so it has to survive one.
    @Test("A subscriber is Plus on the first frame of the next launch")
    func theAnswerSurvivesALaunch() async {
        let front = FakeStoreFront(entitlements: [transaction()])
        let defaults = scratchDefaults()

        let store = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: defaults
        )
        await store.refresh()

        let relaunched = PlusStore(
            front: front,
            entitlements: RecordingEntitlements(),
            defaults: defaults
        )
        #expect(relaunched.isPlus)
    }
}
