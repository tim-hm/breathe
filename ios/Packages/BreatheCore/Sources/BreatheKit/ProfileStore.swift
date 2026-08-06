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
/// `UserDefaults` rather than the Keychain, unlike the identity: reinstalling
/// the app should ask the questions again, because someone who deleted it and
/// came back is a person the app has not met in a while.
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

    private let profiles: any ProfileWriting
    private let defaults: UserDefaults

    public init(profiles: any ProfileWriting, defaults: UserDefaults = .standard) {
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
