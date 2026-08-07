import Foundation
import os

/// The profile as this device holds it, and the one thing that decides whether
/// onboarding runs.
///
/// Local first, server second, and deliberately so: a first-run user must be
/// able to answer five questions on a train with no signal and arrive at a
/// working app. The answers are written to `UserDefaults` before the RPC is
/// attempted, the completion flag is set regardless of whether it succeeds, and
/// anything unsent is retried on the next launch.
///
/// `UserDefaults` rather than the Keychain, unlike the identity: these are
/// answers rather than credentials, and a reinstall is entitled to lose them.
/// What stops that reinstall from *asking again* is the server — `restoredProfile()`
/// reads back what the surviving identity already answered.
@MainActor
@Observable
public final class ProfileStore {
    private static let logger = Logger(category: "profile")

    private static let profileKey = "profile.answers"
    private static let completedKey = "profile.onboardingCompleted"
    private static let pendingKey = "profile.pendingSync"

    /// What this person answered, or `.unanswered` before they have.
    ///
    /// Each of these three writes through on assignment, the same way
    /// `SessionSettings` does: the property is the only thing a mutation has to
    /// remember, so the value in memory and the value on disk cannot drift.
    public private(set) var profile: Profile {
        didSet { persist(profile) }
    }

    /// Whether the stepper has been through to the end. The only gate on
    /// showing it, and set locally, so a person is never asked twice because a
    /// request failed.
    public private(set) var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Self.completedKey) }
    }

    /// How far the stored answers have got towards the server.
    ///
    /// One enum rather than a flag beside a reason, for the usual cause: the two
    /// would admit "outstanding and already refused", which is the state this
    /// exists to make unsayable.
    public enum SyncState: Sendable, Equatable {
        /// The server holds what this device holds.
        case settled
        /// Waiting for a chance to send. Every launch retries.
        case pending
        /// The server refused these answers and would refuse them again, so
        /// nothing retries. Carries its reason, for the screen that asked.
        case rejected(String)
    }

    /// Only `pending` is written to disk, as the flag it has always been: a
    /// relaunch reads a refusal back as `settled` because the whole point of
    /// the case is that no later attempt is made, and a stored one would keep
    /// answering a question with no request behind it.
    public private(set) var syncState: SyncState {
        didSet { defaults.set(syncState == .pending, forKey: Self.pendingKey) }
    }

    /// Whether the stored answers are still waiting to reach the server.
    ///
    /// Not public: no screen asks this, only the guard below and the tests that
    /// pin it, and a second public name for a derived fact is a second thing to
    /// keep in step.
    var isPendingSync: Bool {
        syncState == .pending
    }

    private let profiles: any ProfileSyncing
    private let defaults: UserDefaults

    public init(profiles: any ProfileSyncing, defaults: UserDefaults = .standard) {
        self.profiles = profiles
        self.defaults = defaults

        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the values it just read.
        profile = defaults.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
            // Unreadable answers are dropped rather than repaired, the same rule
            // the session preferences follow: an empty profile is always a valid
            // one, and the questions are one screen away.
            ?? .unanswered
        hasCompletedOnboarding = defaults.bool(forKey: Self.completedKey)
        syncState = defaults.bool(forKey: Self.pendingKey) ? .pending : .settled
    }

    /// Records the answers and closes onboarding, whether or not the network is
    /// there.
    ///
    /// Synchronous on purpose. Awaiting the upload here would put a request
    /// timeout between the last question and the first breath, which is the
    /// exact moment the app has the least credit to spend.
    public func complete(with profile: Profile) {
        self.profile = profile
        syncState = .pending
        hasCompletedOnboarding = true
    }

    /// The answers the server holds, when they are worth adopting.
    ///
    /// The reinstall case: the identity lives in the Keychain and survives one,
    /// while these answers live in `UserDefaults` and do not — so the person the
    /// app has met before arrives looking exactly like a new one, and completing
    /// onboarding again would overwrite the profile they already had.
    ///
    /// Nil covers everything that is not a restore: a local flow that has
    /// already finished, which owns the answers; a server that has never been
    /// told anything; and any failure at all — a first run with no signal is the
    /// normal case, not an error anybody can act on.
    public func restoredProfile() async -> Profile? {
        guard !hasCompletedOnboarding else { return nil }

        do {
            let stored = try await profiles.fetch()
            return stored.hasAnswers ? stored : nil
        } catch {
            Self.logger
                .notice("profile restore deferred: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Takes the server's answers as this device's own and closes onboarding.
    ///
    /// Nothing is left pending: what is being stored *came from* the server, and
    /// sending it back would be a write nobody made — which is the asymmetry
    /// that made a reinstall overwrite a good profile in the first place.
    public func adopt(_ profile: Profile) {
        self.profile = profile
        syncState = .settled
        hasCompletedOnboarding = true
    }

    /// Stores a change made after onboarding — the leaderboard name, the birth
    /// year band — and pushes it if it can.
    ///
    /// Unlike `complete(with:)` this does await the upload, because the one
    /// screen that calls it is showing the person a name the server may change
    /// under them: a taken name comes back suffixed, and they should see that
    /// rather than discover it on a board later. An unreachable server is still
    /// not an error — the answers stay outstanding and the next launch retries.
    /// A *refused* one is different, and `syncState` is how the screen tells the
    /// two apart.
    public func save(_ profile: Profile) async {
        self.profile = profile
        syncState = .pending
        await syncIfNeeded()
    }

    /// Pushes anything the server has not seen.
    ///
    /// Safe to call on every launch and after every change: it returns
    /// immediately when there is nothing outstanding, and a failure it can only
    /// wait out leaves the answers outstanding rather than surfacing an error —
    /// a profile that syncs a day late costs the person nothing.
    public func syncIfNeeded() async {
        guard isPendingSync else { return }

        do {
            // The stored profile is replaced by what came back, so a value the
            // server normalised does not leave this device disagreeing with it
            // and re-syncing forever.
            profile = try await profiles.update(profile)
            syncState = .settled
        } catch let ProfileRepositoryError.rejected(reason) {
            // Cleared rather than left outstanding: the server has judged the
            // answers and not the connection, so every later attempt is the
            // same doomed request on every cold launch for the life of the
            // install. The reason survives for whoever asked for the change.
            Self.logger.notice("profile refused: \(reason)")
            syncState = .rejected(reason)
        } catch {
            Self.logger
                .notice("profile sync deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(_ profile: Profile) {
        guard let encoded = try? JSONEncoder().encode(profile) else { return }
        defaults.set(encoded, forKey: Self.profileKey)
    }
}
