import Foundation
@testable import OndKit
import os
import Testing

// The doubles the account-deletion suite drives its real stores through.
// Split from `AccountDeletionTests` because that file holds a suite whose
// assertions grow one line per store the app learns to erase, and a hundred
// lines of fakes above them is what put it against the file-length limit.
// `RecordingEntitlements` deliberately stayed behind: `SubscriptionTests` has a
// private double of the same name, and an internal one here would shadow
// confusingly rather than collide honestly.

/// A server that erases on demand, or refuses to.
///
/// Only the deletion is modelled: `signIn` is unreachable from every test here
/// and pinned in `AccountModelTests` besides.
final class ErasingAccounts: AccountSyncing {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let failure: (any Error)?

    init(failingWith failure: (any Error)? = nil) {
        self.failure = failure
    }

    /// How many erasures actually reached the server.
    var deletions: Int {
        state.withLock { $0 }
    }

    func signIn(identityToken _: String) async throws -> UUID {
        throw AccountRepositoryError.transport("not what this suite is about")
    }

    func delete() async throws {
        if let failure {
            throw failure
        }

        state.withLock { $0 += 1 }
    }
}

/// A profile server that holds nothing and accepts everything, so the store
/// under test behaves exactly as it does on a device that has been online.
struct SettledProfiles: ProfileSyncing {
    func fetch() async throws -> Profile {
        .unanswered
    }

    @discardableResult
    func update(_ profile: Profile) async throws -> Profile {
        profile
    }
}

/// `StoreKit` with one live subscription on it, which is the state that makes
/// the interesting assertion possible: the account goes, the subscription does
/// not.
struct SubscribedStoreFront: StoreFront {
    func products() async -> [SubscriptionProduct] {
        []
    }

    func currentEntitlements() async -> [SubscriptionTransaction] {
        [
            SubscriptionTransaction(
                id: 1,
                productID: SubscriptionTier.coach.productIdentifier ?? "",
                expirationDate: .distantFuture,
                revocationDate: nil,
                jws: "jws-coach"
            ),
        ]
    }

    func updates() -> AsyncStream<SubscriptionTransaction> {
        AsyncStream { $0.finish() }
    }

    func purchase(_: SubscriptionTier) async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws {}
}

/// Records every list the store re-synced it with, which is how a test sees the
/// pending notification requests being taken back — an empty sync is what
/// removes them.
final class RecordingNotifier: ScheduleNotifying {
    private let state = OSAllocatedUnfairLock(initialState: [[Schedule]]())

    var synced: [[Schedule]] {
        state.withLock { $0 }
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func sync(_ schedules: [Schedule]) async {
        state.withLock { $0.append(schedules) }
    }
}

/// Health that has nothing to say, because none of this is about what it holds —
/// the model stores exactly one thing, and it is the person's own choice.
struct SilentHealthStore: HealthStore {
    func requestReadAuthorization() async {}

    func requestWriteAuthorization() async {}

    func restingHeartRate(from _: Date, to _: Date) async -> [DailyQuantity] {
        []
    }

    func heartRateVariability(from _: Date, to _: Date) async -> [DailyQuantity] {
        []
    }

    func writeMindfulSession(from _: Date, to _: Date) async {}
}
