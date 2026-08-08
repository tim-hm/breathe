import OndUI
import SwiftUI

/// The way out.
///
/// It used to carry the flow's one health note, on the argument that the place
/// to warn somebody is immediately before their first session. That argument
/// won: the note grew into `SafetyConsentStepView`, which is the step directly
/// before this one and is agreed to rather than read past. Repeating it here
/// would be the second copy of a warning this app has just spent a change
/// removing.
struct DoneStepView: View {
    var body: some View {
        OnboardingQuestion(
            title: "That's it.",
            subtitle: "Everything's saved on this device. Pick something and take a few breaths."
        ) {
            EmptyView()
        }
    }
}
