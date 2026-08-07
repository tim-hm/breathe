import BreatheKit
import BreatheUI
import SwiftUI

/// Marks an enum whose question may be declined: the about step's menus draw
/// its cases after a "Rather not say" row, and that row is the `nil` selection
/// rather than a case the model would have to strip before saving.
private protocol RatherNotSayOption: CaseIterable, Identifiable, Hashable {
    var title: String { get }
}

extension BirthYearBand: RatherNotSayOption {}
extension Gender: RatherNotSayOption {}

/// The optional questions: birth decade, gender, and a note for the coach.
///
/// Menus rather than `OnboardingChoice` cards — twelve decade-and-gender
/// options as full-width cards would push the note and the reasons for asking
/// off screen — and "Rather not say" is the selected answer before anyone
/// touches either, so Next untouched is the private answer. The footer owns up
/// to what the answers are for: a question about someone's body should say why
/// it is being asked.
struct AboutYouStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingQuestion(
            title: "A bit about you",
            subtitle: "Entirely optional — rather not say is a complete answer."
        ) {
            optionalPicker("Born", selection: $model.birthYearBand)
            optionalPicker("Gender", selection: $model.gender)

            TextField(
                "Anything you'd like your coach to know?",
                text: $model.intentNote,
                axis: .vertical
            )
            .lineLimit(3 ... 6)
            .font(.body)
            .foregroundStyle(Theme.Ink.primary)
            .padding(Theme.Spacing.standard)
            .background(Theme.Surface.raised, in: card)
            .overlay(card.stroke(Theme.Surface.line, lineWidth: 1))

            Text("These answers tune your coach: your decade and gender let it "
                + "read a breath-test score against the right baseline, and the "
                + "note tells it what you're working towards. Your decade also "
                + "decides which age-band leaderboard you can compare within. "
                + "That's everything they're used for.")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.tertiary)
                .padding(.top, Theme.Spacing.close)
        }
    }

    /// One optional question as a row, drawn like the cards around it.
    private func optionalPicker<Option: RatherNotSayOption>(
        _ label: String,
        selection: Binding<Option?>
    ) -> some View {
        HStack {
            Text(label)
                .font(.headline)
                .foregroundStyle(Theme.Ink.primary)
                // The Picker announces the same label; a second copy would make
                // VoiceOver say "Born" twice per row.
                .accessibilityHidden(true)

            Spacer()

            Picker(label, selection: selection) {
                Text("Rather not say").tag(Option?.none)
                ForEach(Array(Option.allCases)) { option in
                    Text(option.title).tag(Option?.some(option))
                }
            }
            .labelsHidden()
            .tint(Theme.Ink.secondary)
        }
        .padding(.vertical, Theme.Spacing.close)
        .padding(.horizontal, Theme.Spacing.standard)
        .background(Theme.Surface.raised, in: card)
        .overlay(card.stroke(Theme.Surface.line, lineWidth: 1))
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
    }
}
