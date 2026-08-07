import BreatheKit
import BreatheUI
import SwiftUI

/// The first thing anyone sees: a welcome, four questions, and a way out.
///
/// This type is the chrome around them — the step indicator, the switch that
/// picks a step, and the Next/Back/Skip row — while each step is its own
/// `-StepView` beside this file. They are six independent screens that share
/// only that switch, and the layout the questions do share is
/// `OnboardingQuestion`.
///
/// Drawn in the brand accent rather than a goal's, because nothing here belongs
/// to a technique yet. Every question can be passed by — Skip where an answer
/// is wanted, Next where a default already stands — the flow exists to make the
/// app better at its job, not to collect a record before someone is allowed to
/// breathe.
struct OnboardingView: View {
    @State private var model: OnboardingModel

    /// Called when the person leaves the flow. Presentation is the app's
    /// business; by the time this fires the answers are already stored.
    private let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingModel, onFinished: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.loose) {
            progress

            ScrollView {
                step
                    .padding(.horizontal, Theme.Spacing.standard)
                    .padding(.bottom, Theme.Spacing.loose)
            }
            // Cross-fading a whole screen is the transition Reduce Motion is
            // least bothered by, and it still marks that the question changed.
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.step)

            controls
        }
        .padding(.vertical, Theme.Spacing.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.ground)
        // Somebody reinstalling has answered all this before, and the identity
        // that survived in the Keychain can prove it. The flow is drawn first
        // and leaves by itself if the answers arrive.
        .task {
            if await model.restoreIfPossible() {
                onFinished()
            }
        }
    }

    /// One dot per question, the current one stretched — where you are and how
    /// much is left, read at a glance. Absent on the welcome screen, where
    /// there is nothing to be part-way through, and on the last one, where it
    /// would read as unfinished.
    @ViewBuilder
    private var progress: some View {
        if model.canGoBack {
            HStack(spacing: Theme.Spacing.close) {
                ForEach(OnboardingModel.Step.questions) { question in
                    Capsule()
                        .fill(question == model.step ? Theme.Accent.brand : Theme.Surface.line)
                        .frame(width: question == model.step ? 24 : 8, height: 8)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup progress")
            .accessibilityValue(progressDescription)
        }
    }

    private var progressDescription: String {
        let questions = OnboardingModel.Step.questions
        guard let position = questions.firstIndex(of: model.step) else { return "" }
        return "Question \(position + 1) of \(questions.count)"
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: WelcomeStepView()
        case .goals: GoalsStepView(model: model)
        case .experience: ExperienceStepView(model: model)
        case .about: AboutYouStepView(model: model)
        case .reminders: RemindersStepView(model: model)
        case .done: DoneStepView()
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Spacing.close) {
            Button(forwardTitle) {
                if model.step == .done {
                    onFinished()
                } else {
                    model.advance()
                }
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.standard)
            // The ground, so the label inverts with the fill: an accent is dark
            // on white and light on near-black, and a prominent button that kept
            // white text would be unreadable in one of the two.
            .foregroundStyle(Theme.Surface.ground)
            .background(Theme.Accent.brand.opacity(model.canAdvance ? 1 : 0.4), in: Capsule())
            .disabled(!model.canAdvance)

            // Back and Skip share a row under the primary button: Back returns
            // to the previous question, Skip is the way past one that Next is
            // still waiting on. Both keep their place in the layout when
            // absent, so the primary button never moves between steps.
            HStack {
                Button("Back") {
                    model.back()
                }
                .opacity(model.canGoBack ? 1 : 0)
                .disabled(!model.canGoBack)
                .accessibilityHidden(!model.canGoBack)

                Spacer()

                Button("Skip") {
                    model.skip()
                }
                .opacity(model.canSkip ? 1 : 0)
                .disabled(!model.canSkip)
                .accessibilityHidden(!model.canSkip)
            }
            .font(.body)
            .foregroundStyle(Theme.Ink.secondary)
            .padding(.horizontal, Theme.Spacing.standard)
            .padding(.vertical, Theme.Spacing.close)
        }
        .padding(.horizontal, Theme.Spacing.standard)
    }

    private var forwardTitle: String {
        switch model.step {
        case .welcome: "Get started"
        case .reminders: "Save"
        case .done: "Start breathing"
        default: "Next"
        }
    }
}
