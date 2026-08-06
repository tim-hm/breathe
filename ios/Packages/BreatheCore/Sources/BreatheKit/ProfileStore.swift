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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
        category: "profile"
    )

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

    /// Whether the stored answers are still waiting to reach the server.
    public private(set) var isPendingSync: Bool {
        didSet { defaults.set(isPendingSync, forKey: Self.pendingKey) }
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
        isPendingSync = defaults.bool(forKey: Self.pendingKey)
    }

    /// Records the answers and closes onboarding, whether or not the network is
    /// there.
    ///
    /// Synchronous on purpose. Awaiting the upload here would put a request
    /// timeout between the last question and the first breath, which is the
    /// exact moment the app has the least credit to spend.
    public func complete(with profile: Profile) {
        self.profile = profile
        isPendingSync = true
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
            Self.logger.notice("profile restore deferred: \(error.localizedDescription)")
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
        isPendingSync = false
        hasCompletedOnboarding = true
    }

    /// Stores a change made after onboarding — the leaderboard name, the birth
    /// year band — and pushes it if it can.
    ///
    /// Unlike `complete(with:)` this does await the upload, because the one
    /// screen that calls it is showing the person a name the server may change
    /// under them: a taken name comes back suffixed, and they should see that
    /// rather than discover it on a board later. A failure is still not an
    /// error — the flag stays set and the next launch retries.
    public func save(_ profile: Profile) async {
        self.profile = profile
        isPendingSync = true
        await syncIfNeeded()
    }

    /// Pushes anything the server has not seen.
    ///
    /// Safe to call on every launch and after every change: it returns
    /// immediately when there is nothing outstanding, and a failure leaves the
    /// flag set for the next attempt rather than surfacing an error — a profile
    /// that syncs a day late costs the person nothing.
    public func syncIfNeeded() async {
        guard isPendingSync else { return }

        do {
            // The stored profile is replaced by what came back, so a value the
            // server normalised does not leave this device disagreeing with it
            // and re-syncing forever.
            profile = try await profiles.update(profile)
            isPendingSync = false
        } catch {
            Self.logger.notice("profile sync deferred: \(error.localizedDescription)")
        }
    }

    private func persist(_ profile: Profile) {
        guard let encoded = try? JSONEncoder().encode(profile) else { return }
        defaults.set(encoded, forKey: Self.profileKey)
    }
}
