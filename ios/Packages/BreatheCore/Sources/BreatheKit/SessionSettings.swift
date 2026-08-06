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
/// `UserDefaults` rather than the session store: this is a preference, not
/// history, and it is the kind of value that will move onto the profile once
/// there is an identity to hang it on.
@MainActor
@Observable
public final class SessionSettings {
    private static let cueModeKey = "session.cueMode"

    public var cueMode: SessionCueMode {
        didSet { defaults.set(cueMode.rawValue, forKey: Self.cueModeKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read.
        cueMode = defaults.string(forKey: Self.cueModeKey)
            .flatMap(SessionCueMode.init(rawValue:)) ?? .hapticsAndAudio
    }
}
