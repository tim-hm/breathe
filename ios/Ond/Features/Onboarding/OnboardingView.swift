import OndKit
import OndUI
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

    /// Holds the forward button's glass across steps, so it morphs between
    /// questions instead of being torn down and rebuilt: its title changes at
    /// four of the six, and without an identity each new word arrives on a new
    /// slab of glass.
    ///
    /// Only that button. Back and Skip hide themselves with `opacity`, and a
    /// container renders the glass of anything it has an id for whether the
    /// view asked to be seen or not — so an id on either of those draws a pill
    /// on the welcome step, where neither control applies.
    @Namespace private var forwardGlass

    /// Whether the about step's note has the keyboard.
    ///
    /// Held here rather than in the step that owns the field, because the
    /// control row is what has to react: it floats in a bottom inset, so a
    /// raised keyboard lifts it directly over the field being typed into. It
    /// stands down for the duration and the keyboard's own Done takes over.
    @FocusState private var isEditingNote: Bool

    init(model: OnboardingModel, onFinished: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        ScrollView {
            step
                .padding(.horizontal, Theme.Spacing.standard)
                .padding(.vertical, Theme.Spacing.loose)
                // One question blurs into the next, and a plain cross-fade is
                // what Reduce Motion gets instead. The `id` is what makes
                // either of them fire: without it the switch below swaps its
                // branches inside a view whose identity never changes, and a
                // transition on a view that is never inserted or removed does
                // nothing at all.
                //
                // Both sides spelled as `AnyTransition` because the two do not
                // otherwise share a type — `blurReplace` is a `Transition` and
                // `opacity` is not — and a ternary needs one.
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                .id(model.step)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.step)
        .scrollDismissesKeyboard(.interactively)
        // Insets rather than a `VStack`: the chrome then floats over the
        // question, the system fades content under it at the scroll edges, and
        // the welcome step — which has no progress row — gets the whole screen
        // without anything here branching on the step.
        .safeAreaInset(edge: .top) { progress }
        .safeAreaInset(edge: .bottom) { controls }
        .paletteGround()
        // The ground reaches the status bar and the home indicator, which a
        // background inside the safe area cannot: a cover otherwise keeps the
        // system's own backdrop in both margins, and that is white by day and
        // pure black at night — neither of them this palette.
        .presentationBackground(Theme.Surface.ground)
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
    /// much is left, read at a glance. Only on the questions it counts: the
    /// welcome, the safety terms, and the last screen are not places to be
    /// part-way through, and a row of dots with none of them lit is worse than
    /// no row at all.
    @ViewBuilder
    private var progress: some View {
        if OnboardingModel.Step.questions.contains(model.step) {
            HStack(spacing: Theme.Spacing.close) {
                ForEach(OnboardingModel.Step.questions) { question in
                    Capsule()
                        .fill(question == model.step ? Theme.Accent.brand : Theme.Surface.line)
                        .frame(width: question == model.step ? 24 : 8, height: 8)
                }
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .padding(.vertical, Theme.Spacing.close)
            // A pill of its own rather than dots loose on the ground: the
            // question now scrolls underneath them, and four 8pt marks with
            // nothing behind them would cross the copy on the way past.
            .glassEffect(in: .capsule)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup progress")
            .accessibilityValue(progressDescription)
            .padding(.bottom, Theme.Spacing.close)
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
        case .about: AboutYouStepView(model: model, isEditingNote: $isEditingNote)
        case .reminders: RemindersStepView(model: model)
        case .safety: SafetyConsentStepView(terms: model.safetyTerms)
        case .done: DoneStepView()
        }
    }

    @ViewBuilder
    private var controls: some View {
        if !isEditingNote {
            VStack(spacing: Theme.Spacing.close) {
                // Wraps the forward button alone. A container renders its
                // descendants' glass in a layer of its own, which is what lets two
                // pills blend and morph — and also what puts that glass beyond the
                // reach of a descendant's `opacity`. Back and Skip hide themselves
                // that way, so they stay outside it.
                GlassEffectContainer {
                    Button {
                        if model.step == .done {
                            onFinished()
                        } else {
                            model.advance()
                        }
                    } label: {
                        // Inside the label, which is the whole point: a `frame` and
                        // a `background` hung on the button itself draw a shape the
                        // button does not consider part of itself, and every tap
                        // that lands beside the word misses.
                        Text(forwardTitle)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.tight)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Accent.brand)
                    .controlSize(.large)
                    .glassEffectID(Control.forward, in: forwardGlass)
                    .disabled(!model.canAdvance)
                }

                // Back and Skip share a row under the primary button: Back
                // returns to the previous question, Skip is the way past one
                // that Next is still waiting on. Both keep their place in the
                // layout when absent, so the primary button never moves between
                // steps.
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
                .buttonStyle(.glass)
                // Held back from the accent the button above takes, so the row
                // reads as the two ways out of a question rather than three
                // things of equal weight.
                .tint(Theme.Ink.secondary)
                .font(.body)
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .padding(.top, Theme.Spacing.close)
        }
    }

    /// The control whose glass persists across steps, named so
    /// `glassEffectID` has something stable to hold it by.
    private enum Control {
        case forward
    }

    private var forwardTitle: String {
        switch model.step {
        case .welcome: "Get started"
        case .reminders: "Save"
        // The agreement's own words rather than "Next": what this button does is
        // record a consent, and it has to say so.
        case .safety: model.safetyTerms.agreement
        case .done: "Start breathing"
        default: "Next"
        }
    }
}
