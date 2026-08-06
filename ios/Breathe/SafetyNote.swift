import BreatheKit
import BreatheUI
import SwiftUI

/// The caution a technique carries, where it carries one.
///
/// App-local rather than inside either feature, because the same words have to
/// appear on the detail screen — where someone decides — and inside the session,
/// where someone is already breathing. A warning only the catalogue shows is one
/// the person has scrolled past by the time it matters.
struct SafetyNote: View {
    let technique: Technique
    /// Smaller inside the session, where the screen belongs to the breath.
    var font: Font = .footnote

    var body: some View {
        if let note = technique.safetyNote {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.close) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Accent.caution)
                Text(note)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .font(font)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Spacing.standard))
            // One VoiceOver element: the icon says nothing the words do not.
            .accessibilityElement(children: .combine)
        }
    }
}
