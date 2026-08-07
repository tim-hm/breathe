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

/// How hard the phone taps.
///
/// Three steps rather than a slider: the useful range is narrow, the difference
/// between neighbouring percentages is not perceptible, and a person adjusting
/// this is answering "I can barely feel it" rather than dialling a number.
///
/// The scale and the boost are applied to values *authored* in
/// `HapticController`'s patterns, which is why `standard` is exactly identity —
/// today's feel is the reference the other two are named against, and a default
/// that quietly re-tuned every pattern would be a change nobody asked for.
///
/// Watch-only builds never see this: `WKHapticType` has no intensity at all, so
/// the wrist plays what the system plays.
public enum HapticStrength: String, Sendable, CaseIterable, Identifiable, Codable {
    case gentle
    case standard
    case strong

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .strong: "Strong"
        }
    }

    /// What an authored intensity is multiplied by.
    private var scale: Float {
        switch self {
        case .gentle: 0.6
        case .standard: 1
        case .strong: 1.4
        }
    }

    /// What is added to an authored sharpness.
    ///
    /// Carried alongside the scale because intensity alone cannot deliver
    /// "stronger": the patterns are authored up to 0.9, so scaling has barely a
    /// tenth of headroom before it clips. Sharpness is the other axis — it is
    /// what makes a tap read as a crisp knock rather than a soft push — and it
    /// is where most of `strong`'s extra actually comes from.
    private var edge: Float {
        switch self {
        case .gentle: -0.15
        case .standard: 0
        case .strong: 0.25
        }
    }

    /// `authored` at this strength, kept inside the 0...1 the engine accepts.
    ///
    /// Floored just above zero rather than at it: a scaled-down inhale that
    /// reached exactly zero would be a phase with no cue at all, which is not
    /// what "gentle" was asked for.
    public func intensity(_ authored: Float) -> Float {
        clamped(authored * scale, floor: 0.05)
    }

    /// `authored` at this strength, kept inside the 0...1 the engine accepts.
    public func sharpness(_ authored: Float) -> Float {
        clamped(authored + edge, floor: 0)
    }

    private func clamped(_ value: Float, floor: Float) -> Float {
        min(max(value, floor), 1)
    }
}

/// How much the session says while it guides.
///
/// The dial a person turns down as a technique stops needing narration: full
/// keeps the instruction, the countdown, and the phase hints on screen;
/// essentials leaves the orb to carry the session. Safety copy is not
/// guidance and never obeys this, and neither do VoiceOver announcements —
/// wanting less on screen is not the same as hearing nothing.
public enum SessionGuidance: String, Sendable, CaseIterable, Identifiable {
    case full
    case essentials

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .full: "Full guidance"
        case .essentials: "Just the visuals"
        }
    }
}

/// Which colour scheme the app draws in.
///
/// `system` is the default and the absence of an opinion. Every token in the
/// palette carries a light and a dark value (M3), so this is one override at
/// the root of the view tree — never a per-view branch, which is exactly the
/// thing the token system exists to prevent.
public enum Appearance: String, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .system: "Match the system"
        case .light: "Light"
        case .dark: "Dark"
        }
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
    private static let appearanceKey = "app.appearance"
    private static let cueModeKey = "session.cueMode"
    private static let guidanceKey = "session.guidance"
    private static let hapticStrengthKey = "session.hapticStrength"
    private static let lastGoalKey = "home.lastGoal"
    private static let overridesKey = "session.techniqueOverrides"

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    public var cueMode: SessionCueMode {
        didSet { defaults.set(cueMode.rawValue, forKey: Self.cueModeKey) }
    }

    public var guidance: SessionGuidance {
        didSet { defaults.set(guidance.rawValue, forKey: Self.guidanceKey) }
    }

    /// How hard the taps land. Separate from `cueMode`, which decides *whether*
    /// there are taps: wanting haptics and wanting them stronger are different
    /// questions, and folding them into one control would mean a person who
    /// turns the strength down loses the channel.
    public var hapticStrength: HapticStrength {
        didSet { defaults.set(hapticStrength.rawValue, forKey: Self.hapticStrengthKey) }
    }

    /// Where the intent wheel last sat, restored on the next launch — the
    /// home screen remembers what this person wanted rather than guessing
    /// again. Nil until the wheel is first moved; the time-of-day rule covers
    /// that first launch.
    public var lastGoal: TechniqueGoal? {
        didSet { defaults.set(lastGoal?.rawValue, forKey: Self.lastGoalKey) }
    }

    /// Every technique the person has dialled, keyed by slug — the key the
    /// catalogue promises to keep stable across reseeds.
    ///
    /// One blob rather than a default per technique: the whole set is read on
    /// launch and written on any change, so a key each would buy nothing but
    /// more keys. It stays on the device — see `TechniqueOverrides` for why the
    /// profile is not where this belongs.
    private var overridesBySlug: [String: TechniqueOverrides] {
        didSet { persistOverrides() }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read.
        appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(Appearance.init(rawValue:)) ?? .system
        cueMode = defaults.string(forKey: Self.cueModeKey)
            .flatMap(SessionCueMode.init(rawValue:)) ?? .hapticsAndAudio
        hapticStrength = defaults.string(forKey: Self.hapticStrengthKey)
            .flatMap(HapticStrength.init(rawValue:)) ?? .standard
        guidance = defaults.string(forKey: Self.guidanceKey)
            .flatMap(SessionGuidance.init(rawValue:)) ?? .full
        lastGoal = defaults.string(forKey: Self.lastGoalKey)
            .flatMap(TechniqueGoal.init(rawValue:))
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
