import OndKit
import OndUI
import SwiftUI

/// The safety terms, and the last screen before anybody breathes.
///
/// This is what replaced a caution on every exercise card and detail screen. It
/// is a wall on purpose, in a flow whose every other step can be passed by: the
/// hazards are unrelated to each other and there is no longer anywhere else the
/// app says them, so the one screen that does has to be met rather than
/// scrolled past. `OnboardingModel` withholds Skip and Back here for the same
/// reason, and the forward button carries the agreement's own words.
///
/// The copy is `SafetyConsent`'s, not this view's. What is rendered and what is
/// recorded have to be the same words, and a literal typed into a `Text` here
/// would be a third copy nobody keeps in step.
struct SafetyConsentStepView: View {
    let terms: SafetyConsent

    var body: some View {
        OnboardingQuestion(title: terms.title, subtitle: terms.intro) {
            VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                ForEach(terms.points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.close) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.Accent.caution)

                        Text(point)
                            .font(.callout)
                            .foregroundStyle(Theme.Ink.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // One element per hazard rather than one for the list: read
                    // as a single block, five unrelated warnings become one long
                    // sentence, and VoiceOver users get no way to stop between
                    // them.
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Theme.Spacing.standard)
            .glassCard()
        }
    }
}
