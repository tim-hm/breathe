import OndKit
import OndUI
import SwiftUI

/// How much to explain as the session goes. Drawn in the brand accent, not a
/// goal's: the answer belongs to the person rather than to any exercise.
struct ExperienceStepView: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingQuestion(
            title: "Have you done this before?",
            subtitle: "Every exercise is available either way. This only decides how much "
                + "we explain as you go."
        ) {
            ForEach(ExperienceLevel.allCases) { level in
                OnboardingChoice(
                    title: level.title,
                    detail: level.detail,
                    isSelected: model.experienceLevel == level,
                    accent: Theme.Accent.brand
                ) {
                    model.experienceLevel = level
                }
            }
        }
    }
}
