import BreatheKit
import BreatheUI
import SwiftUI

/// The caution an exercise carries, given the room to actually be read, on the
/// screen where somebody is deciding whether to breathe it.
///
/// Deliberately large the first time: a run of footnote text under a chart is
/// something people scroll past, and a warning nobody reads is not a warning.
/// The glyph sits above the words rather than beside them so the card has a
/// shape you cannot mistake for body copy.
///
/// It can then be put away — per exercise, never globally, which is
/// `SafetyNoteStore`'s whole reason for existing — and putting it away collapses
/// it to a control that opens the same words again. It stops being an
/// obstruction; it never stops being available. `SafetyNote` is the compact
/// version the session player shows, which asks this store nothing.
struct SafetyNoteCard: View {
    let technique: Technique

    @Environment(SafetyNoteStore.self) private var dismissals

    /// Set by the collapsed control, and cleared by the card's own button.
    /// View state rather than a second flag in the store: reopening a note is
    /// about this visit to the screen, not about the preference.
    @State private var isReopened = false

    var body: some View {
        if let note = technique.safetyNote {
            Group {
                if dismissals.hasDismissed(technique), !isReopened {
                    collapsed
                } else {
                    card(note)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isReopened)
        }
    }

    private func card(_ note: String) -> some View {
        VStack(spacing: Theme.Spacing.standard) {
            VStack(spacing: Theme.Spacing.standard) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Accent.caution)

                Text(note)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Ink.primary)
            }
            // One element, and the caution is named before the words rather
            // than left to an icon VoiceOver would otherwise skip.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Caution. \(note)")

            Button("Got it") {
                dismissals.dismiss(technique)
                isReopened = false
            }
            .buttonStyle(.bordered)
            .tint(Theme.Accent.caution)
            .accessibilityLabel("Got it")
            .accessibilityHint("Puts this caution away. It stays available below.")
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.loose)
        .background(
            Theme.Accent.caution.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Accent.caution.opacity(0.35))
        )
    }

    /// What is left once the card is put away: quiet, but still on the screen
    /// and still a way back to the words.
    private var collapsed: some View {
        Button {
            isReopened = true
        } label: {
            HStack(spacing: Theme.Spacing.close) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Safety note")
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(Theme.Accent.caution)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Safety note")
        .accessibilityHint("Shows the caution for this exercise again")
    }
}
