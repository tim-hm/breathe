import OndKit
import OndUI
import SwiftUI

/// The caution an exercise carries, compact, under the breath guide.
///
/// The last inline caution left in the phone app, and deliberately so. Every
/// other one — the card on the detail screen, the icons in the lists — was
/// replaced by the single consent step in onboarding, because a hazard named
/// once and agreed to is better read than the same hazard named on nine screens
/// and skimmed on all of them. This one stayed because it is the only one that
/// would have removed a warning from the moment of risk rather than moving it:
/// "never in water, never in the bath" is not general advice that a screen seen
/// weeks ago discharges.
///
/// Two exercises reach it, and no view here knows which. `safetyNote` is now
/// non-empty in the seeded catalogue exactly where a caution has to interrupt a
/// session, so a tenth technique that can make somebody faint gets this line by
/// filling in a field rather than by anyone remembering this decision.
///
/// Nothing about it is dismissible, and there is no longer a store that could
/// make it so. The watch draws its own — the wrist has no room for this one.
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
