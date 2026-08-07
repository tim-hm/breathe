import Foundation
import Observation

/// The one preference the wrist has.
///
/// Watch-local rather than `BreatheKit`'s `SessionSettings`, which was checked
/// first and does not drop in: it carries an appearance override, a guidance
/// level, the home wheel's last goal, and every technique the person has
/// dialled — none of which the watch has a screen for — and its `SessionCueMode`
/// third case is audio the wrist does not play. A settings screen offering one
/// switch should not drag four unreachable preferences behind it.
///
/// `UserDefaults` for the same reason the phone's is: this is a preference, not
/// history, and it belongs to the device it was set on.
@MainActor
@Observable
final class WatchSettings {
    private static let hapticsKey = "session.haptics"

    /// Whether phase boundaries are felt. Off leaves a visual-only session,
    /// which is the whole point of the switch: the same technique, silently,
    /// for a room or a wrist that should not be tapped.
    var playsHaptics: Bool {
        didSet { defaults.set(playsHaptics, forKey: Self.hapticsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`, which cannot tell a
        // key nobody has written from a stored false — and the default is on.
        // Assigning in an initialiser does not run `didSet`, which is what
        // keeps this from writing back the value it just read.
        playsHaptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
    }
}
