import OndKit
import WatchKit

/// The wrist breathing with you: one discrete tap at each phase boundary.
///
/// The watch's answer to the phone's `HapticController`, and a deliberately
/// poorer one — watchOS has no CoreHaptics, so a phase cannot be shaped, only
/// marked. `WatchCue` holds which tap each phase earns and is pinned by a host
/// test; this type is the half that can only be judged on a wrist, so it does
/// nothing but translate.
///
/// Nothing to prepare and nothing to release: `WKInterfaceDevice` plays a tap
/// with no engine behind it to warm up or leak.
@MainActor
final class WatchHapticController: SessionCueing {
    /// Read on every cue rather than resolved at composition, so a switch
    /// flicked between choosing a technique and finishing it takes effect on
    /// the next boundary instead of the next session.
    private let settings: WatchSettings

    init(settings: WatchSettings) {
        self.settings = settings
    }

    func prepare() {}

    func play(_ beat: SessionTimeline.Beat) {
        play(WatchCue(beat.kind))
    }

    func playCompletion() {
        play(.complete)
    }

    func stop() {}

    /// The one place `WKHapticType` is named.
    ///
    /// `.directionUp` and `.directionDown` are the only pair in the vocabulary
    /// that are opposites by design rather than by intensity, which is what
    /// makes an inhale and an exhale tell apart with your eyes shut. `.click` is
    /// the shortest neutral tap there is, so a hold reads as a boundary without
    /// suggesting a direction to move in.
    private func play(_ cue: WatchCue) {
        guard settings.playsHaptics else { return }

        let haptic: WKHapticType = switch cue {
        case .rise: .directionUp
        case .fall: .directionDown
        case .mark: .click
        case .complete: .success
        }

        WKInterfaceDevice.current().play(haptic)
    }
}
