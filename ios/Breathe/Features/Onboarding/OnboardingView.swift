import BreatheKit
import BreatheUI
import SwiftUI

/// The first thing anyone sees: a welcome, three questions, and a way out.
///
/// Drawn in the brand accent rather than a goal's, because nothing here belongs
/// to a technique yet. Every question can be passed by — Skip where an answer
/// is wanted, Next where a default already stands — the flow exists to make the
/// app better at its job, not to collect a record before someone is allowed to
/// breathe.
struct OnboardingView: View {
    @State private var model: OnboardingModel

    /// Whether the welcome copy has floated in yet. Starts false so the first
    /// screen arrives rather than being merely there.
    @State private var hasArrived = false

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
        case .welcome: welcome
        case .goals: goals
        case .experience: experience
        case .reminders: reminders
        case .done: done
        }
    }

    /// The splash: the orb already breathing, and a welcome rather than a
    /// form. Centred where every question is leading-aligned — this screen is
    /// a greeting, not a step, and the layout should say so.
    private var welcome: some View {
        VStack(spacing: Theme.Spacing.loose) {
            AmbientOrb(accent: Theme.Accent.brand)
                .padding(.top, Theme.Spacing.loose)

            VStack(spacing: Theme.Spacing.standard) {
                Text("BREATHE")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .tracking(7)
                    .foregroundStyle(Theme.Ink.secondary)

                Text("We're glad you're here.")
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(Theme.Ink.primary)

                Text(
                    "A few minutes of guided breathing can steady a hard day, "
                        + "settle you towards sleep, or sharpen an afternoon — and "
                        + "you're about to feel it for yourself."
                )
                .font(.body)
                .foregroundStyle(Theme.Ink.secondary)

                Text("Three quick questions first, then we'll get out of your way.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The one entrance in the app: the words rise to meet the orb,
            // which is already breathing when they arrive.
            .opacity(hasArrived ? 1 : 0)
            .offset(y: hasArrived || reduceMotion ? 0 : 12)
            .animation(.easeOut(duration: 0.8).delay(0.2), value: hasArrived)
        }
        .frame(maxWidth: .infinity)
        .onAppear { hasArrived = true }
    }

    private var goals: some View {
        question(
            "What brings you here?",
            "Pick as many as you like — it decides what we show you first."
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

    private var experience: some View {
        question(
            "Have you done this before?",
            "Every technique is available either way. This only decides how much "
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

    /// The dial whose default is silence.
    ///
    /// `Never` is listed first and is already selected, so leaving the screen
    /// untouched is the private answer. The footnote owns up to both
    /// consequences of moving it: a reminder appears in Settings, and iOS asks
    /// about notifications — nobody should meet either unwarned.
    private var reminders: some View {
        question(
            "Want a nudge?",
            "Entirely up to you."
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

    private var done: some View {
        question(
            "That's it.",
            "Everything's saved on this device. Pick something and take a few breaths."
        ) {
            safetyDisclaimer
        }
    }

    /// The one health note the flow carries, on the way out rather than the
    /// way in: some techniques breathe fast enough to make a person
    /// light-headed, and the place to say so is before the first session, not
    /// buried in a technique's small print.
    private var safetyDisclaimer: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.close) {
            Image(systemName: "heart.circle")
                .font(.title3)
                .foregroundStyle(Theme.Accent.brand)

            Text(
                "One thing before you begin: some techniques use quick, deep "
                    + "breathing that can leave you light-headed. Practise sitting "
                    + "or lying down — never while driving or in water — and if "
                    + "anything feels wrong, just breathe normally."
            )
            .font(.footnote)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(Theme.Spacing.standard)
        .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Surface.line)
        )
        .accessibilityElement(children: .combine)
    }

    /// One question's layout: a heading, a line of context, and whatever it asks.
    private func question(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Text(title)
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(Theme.Ink.primary)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
