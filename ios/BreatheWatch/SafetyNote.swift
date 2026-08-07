import BreatheKit
import BreatheUI
import SwiftUI

/// The caution a technique carries, where it carries one.
///
/// The wrist's version of the phone's note, and its own view rather than a
/// shared one: this is caption-sized, wraps rather than truncates, and carries
/// no card. One note taking a font, a card flag and a wrap flag would be a worse
/// type than two that each say one thing.
///
/// Shown while choosing and not while breathing — the phone repeats it
/// in-session because it has the room, and a watch face given over to a warning
/// is a watch face nobody can read the phase off.
struct SafetyNote: View {
    let technique: Technique

    var body: some View {
        if let note = technique.safetyNote {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Accent.caution)
                Text(note)
                    .foregroundStyle(Theme.Ink.secondary)
                    // A caution is the one thing on this screen that may not be
                    // truncated, and a `Text` beside an icon in a card that
                    // sizes to its content will otherwise take one line and an
                    // ellipsis.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            // One VoiceOver element: the icon says nothing the words do not.
            .accessibilityElement(children: .combine)
        }
    }
}
