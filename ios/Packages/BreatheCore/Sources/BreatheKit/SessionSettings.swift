import Foundation
import Observation

/// Which cues accompany the animation.
///
/// Haptics and audio are separable because the situations differ: a phone face
/// down in a pocket needs the taps and nothing else, a quiet office needs
/// neither, and both need the same session underneath.
public enum SessionCueMode: String, Sendable, CaseIterable, Identifiable {
    case hapticsAndAudio
    case haptics
    case visualOnly

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .hapticsAndAudio: "Haptics & sound"
        case .haptics: "Haptics only"
        case .visualOnly: "Visual only"
        }
    }

    public var playsHaptics: Bool {
        self != .visualOnly
    }

    public var playsAudio: Bool {
        self == .hapticsAndAudio
    }
}

/// The session preferences that survive a launch.
///
/// `UserDefaults` rather than the session store: these are preferences, not
/// history, and they are the kind of value that will move onto the profile once
/// there is an identity to hang them on.
@MainActor
@Observable
public final class SessionSettings {
    private static let cueModeKey = "session.cueMode"
    private static let overridesKey = "session.techniqueOverrides"

    public var cueMode: SessionCueMode {
        didSet { defaults.set(cueMode.rawValue, forKey: Self.cueModeKey) }
    }

    /// Every technique the person has dialled, keyed by slug — the key the
    /// catalogue promises to keep stable across reseeds.
    ///
    /// One blob rather than a default per technique: the whole set is read on
    /// launch and written on any change, and a single key is one thing to
    /// migrate when M4 moves this onto the profile.
    private var overridesBySlug: [String: TechniqueOverrides] {
        didSet { persistOverrides() }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read.
        cueMode = defaults.string(forKey: Self.cueModeKey)
            .flatMap(SessionCueMode.init(rawValue:)) ?? .hapticsAndAudio
        overridesBySlug = defaults.data(forKey: Self.overridesKey)
            .flatMap { try? JSONDecoder().decode([String: TechniqueOverrides].self, from: $0) }
            // Unreadable stored preferences are dropped rather than repaired:
            // the curated defaults are always a correct session, and the person
            // is one visit to Advanced away from their own again.
            ?? [:]
    }

    /// What this person dialled for `technique`, or nil where they took it as
    /// the catalogue curated it.
    public func overrides(for technique: Technique) -> TechniqueOverrides? {
        overridesBySlug[technique.slug]
    }

    /// Stores a dialled technique, or clears it back to the curated defaults
    /// when `overrides` is nil or matches them exactly — so "reset" leaves
    /// nothing behind to outlive a change to the catalogue.
    public func setOverrides(_ overrides: TechniqueOverrides?, for technique: Technique) {
        if let overrides, overrides != technique.curatedOverrides {
            overridesBySlug[technique.slug] = overrides
        } else {
            overridesBySlug.removeValue(forKey: technique.slug)
        }
    }

    private func persistOverrides() {
        guard let encoded = try? JSONEncoder().encode(overridesBySlug) else { return }
        defaults.set(encoded, forKey: Self.overridesKey)
    }
}
