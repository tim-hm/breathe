import BreatheKit
import BreatheUI
import SwiftUI

/// The first thing anyone sees: five questions and a way out.
///
/// Drawn in the brand accent rather than a goal's, because nothing here belongs
/// to a technique yet. Every question but the experience one can be left blank —
/// the flow exists to make the app better at its job, not to collect a record
/// before someone is allowed to breathe.
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
    }

    /// Absent on the welcome screen, where there is nothing to be part-way
    /// through, and on the last one, where it would read as unfinished.
    @ViewBuilder
    private var progress: some View {
        if model.step != .welcome, model.step != .done {
            ProgressView(value: model.progress)
                .tint(Theme.Accent.brand)
                .padding(.horizontal, Theme.Spacing.standard)
                .accessibilityLabel("Setup progress")
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: welcome
        case .goals: goals
        case .experience: experience
        case .reminders: reminders
        case .intent: intent
        case .done: done
        }
    }

    private var welcome: some View {
        question(
            "Breathe",
            "A few questions, then we'll get out of your way. You can change any "
                + "of it later, and you can skip anything you'd rather not answer."
        ) {
            EmptyView()
        }
    }

    private var goals: some View {
        question(
            "What brings you here?",
            "Pick as many as you like, or none — it decides what we show you first."
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
    /// untouched is the private answer. The footnote says so out loud rather
    /// than leaving someone to work out that they have not opted into anything.
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
                + "We'll only ask for notification permission if you don't pick it.")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.tertiary)
                .padding(.top, Theme.Spacing.close)
        }
    }

    private var intent: some View {
        question(
            "Anything you want to say?",
            "Optional, and in your own words. It helps us suggest something that fits."
        ) {
            TextField(
                "I'd like to stop clenching my jaw",
                text: $model.intentNote,
                axis: .vertical
            )
            .lineLimit(3 ... 6)
            .textFieldStyle(.plain)
            .padding(Theme.Spacing.standard)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.Surface.line)
            )
            .accessibilityLabel("What brings you here, in your own words")
            .onChange(of: model.intentNote) { _, note in
                // Stopped at the length the server accepts rather than letting
                // someone write past it and meet a rejection at save time.
                if note.count > Profile.maxIntentNoteLength {
                    model.intentNote = String(note.prefix(Profile.maxIntentNoteLength))
                }
            }
        }
    }

    private var done: some View {
        question(
            "That's it.",
            "Everything's saved on this device. Pick something and take a few breaths."
        ) {
            EmptyView()
        }
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
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.close)
            // The ground, so the label inverts with the fill: an accent is dark
            // on white and light on near-black, and a prominent button that kept
            // white text would be unreadable in one of the two.
            .foregroundStyle(Theme.Surface.ground)
            .background(Theme.Accent.brand.opacity(model.canAdvance ? 1 : 0.4), in: Capsule())
            .disabled(!model.canAdvance)

            Button("Back") {
                model.back()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.Ink.secondary)
            // Kept in the layout rather than removed, so the forward button does
            // not move up the screen between the first question and the second.
            .opacity(model.step == .welcome || model.step == .done ? 0 : 1)
            .disabled(model.step == .welcome || model.step == .done)
            .accessibilityHidden(model.step == .welcome || model.step == .done)
        }
        .padding(.horizontal, Theme.Spacing.standard)
    }

    private var forwardTitle: String {
        switch model.step {
        case .welcome: "Get started"
        case .intent: "Save"
        case .done: "Start breathing"
        default: "Next"
        }
    }
}
