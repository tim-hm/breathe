import BreatheKit
import BreatheUI
import SwiftUI

/// The dial whose default is silence.
///
/// `Never` is listed first and is already selected, so leaving the screen
/// untouched is the private answer. The footnote owns up to both consequences of
/// moving it: a reminder appears in Settings, and iOS asks about notifications —
/// nobody should meet either unwarned.
struct RemindersStepView: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingQuestion(
            title: "Want a nudge?",
            subtitle: "Entirely up to you."
        ) {
            ForEach(ReminderIntensity.allCases) { intensity in
                OnboardingChoice(
                    title: intensity.title,
                    detail: intensity.detail,
                    isSelected: model.reminderIntensity == intensity,
                    accent: Theme.Accent.brand
                ) {
                    model.reminderIntensity = intensity
                }
            }

            Text("Never is the default, and it stays that way unless you move it. "
                + "Pick a nudge and we'll set a reminder up for you — change it, "
                + "or let it go, in Settings whenever you like. iOS will ask for "
                + "notification permission; that's the only permission the app "
                + "ever requests.")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.tertiary)
                .padding(.top, Theme.Spacing.close)
        }
    }
}
