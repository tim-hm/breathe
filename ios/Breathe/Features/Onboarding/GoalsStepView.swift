import BreatheKit
import BreatheStyle
import SwiftUI

/// What brings you here — the one question whose answer is a list rather than a
/// single choice, and the one the rest of the app reads most.
struct GoalsStepView: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingQuestion(
            title: "What brings you here?",
            subtitle: "Pick as many as you like — it decides what we show you first."
        ) {
            ForEach(TechniqueGoal.allCases, id: \.self) { goal in
                OnboardingChoice(
                    title: goal.title,
                    detail: nil,
                    isSelected: model.isSelected(goal),
                    accent: goal.accent
                ) {
                    model.toggle(goal)
                }
            }
        }
    }
}
