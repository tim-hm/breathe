import OndKit
import OndUI
import SwiftUI

/// The caution an exercise carries, compact, for a screen that belongs to
/// something else.
///
/// The session player is the only user: the contraindications belong where the
/// person is, not only where they chose, and nothing about this one is
/// dismissible. Somebody who is already breathing is exactly who the words are
/// for.
///
/// `SafetyNoteCard` is the same words given the room to be read before anything
/// starts. Two views rather than one taking flags, because the browsing one
/// carries dismissal state and this one must never learn about it.
///
/// The watch draws its own — the wrist has no room for either of these.
struct SafetyNote: View {
    let technique: Technique

    var body: some View {
        if let note = technique.safetyNote {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.close) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Accent.caution)
                Text(note)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .font(.caption)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            // One VoiceOver element, with the caution named first: the icon
            // carries that meaning for everyone who can see it.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Caution. \(note)")
        }
    }
}
