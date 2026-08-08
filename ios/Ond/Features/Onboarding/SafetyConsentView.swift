import OndKit
import OndUI
import SwiftUI

/// The safety terms on their own, for somebody who onboarded before they
/// existed.
///
/// The alternative was to treat an install that predates this screen as having
/// already agreed, which is the one thing a consent record may not do: no record
/// means not asked, and not asked means ask. Reopening the whole flow would ask
/// five questions they have already answered, so the step is lifted out of it
/// and given the chrome it borrowed from `OnboardingView` — the ground, and one
/// button.
///
/// Shown once. Agreeing writes the record, `needsConsent` never comes back true
/// for these terms, and there is no other way off the screen — no close button,
/// and a full-screen cover cannot be swiped away.
struct SafetyConsentView: View {
    let store: SafetyConsentStore
    let onAgreed: () -> Void

    var body: some View {
        ScrollView {
            SafetyConsentStepView(terms: store.terms)
                .padding(.horizontal, Theme.Spacing.standard)
                .padding(.vertical, Theme.Spacing.loose)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                store.record()
                onAgreed()
            } label: {
                Text(store.terms.agreement)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.tight)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.Accent.brand)
            .controlSize(.large)
            .padding(.horizontal, Theme.Spacing.standard)
            .padding(.top, Theme.Spacing.close)
        }
        .paletteGround()
        // The same reason `OnboardingView` sets it: a cover otherwise keeps the
        // system's backdrop in the status bar and home indicator margins, and
        // that is white by day and pure black at night — neither of them this
        // palette.
        .presentationBackground(Theme.Surface.ground)
    }
}
