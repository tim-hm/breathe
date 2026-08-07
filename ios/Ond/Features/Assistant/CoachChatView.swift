import OndKit
import OndUI
import SwiftUI

/// The conversation with the coach — prose on the app's own ground, not a
/// messenger pastiche.
///
/// No bubbles, no avatars, no timestamps: the person's questions sit small and
/// quiet, the coach's answers read as body text, and the whole screen keeps
/// the calm register of the exercise pages the coach talks about. Reached only
/// from the Exercises tab's coach line, and only by Coach holders — the tier
/// gate lives at that entry, not here.
///
/// Phone-only by design. The watch deliberately has no chat surface: text
/// entry is hostile on the wrist, and dictating a coaching question into a
/// watch is not a conversation anybody asked for.
struct CoachChatView: View {
    @State private var model: CoachChatModel
    @State private var draft = ""

    /// Defaulted for `WhyThisWorksView`'s reason: the view drops into the
    /// navigation stack without its screen learning where the dependencies
    /// come from.
    init(
        assistant: any AssistantReading = LiveAssistant.reading,
        voice: any CoachVoice = LiveCoachVoice.voice
    ) {
        _model = State(wrappedValue: CoachChatModel(assistant: assistant, voice: voice))
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            composer
        }
        .paletteGround()
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                speakBackToggle
            }
        }
        // The stream and the voice both die with the screen — a request
        // nobody is watching and a monologue nobody is hearing.
        .onDisappear { model.cancel() }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                if model.transcript.isEmpty {
                    opening
                }

                ForEach(model.transcript) { turn in
                    row(for: turn)
                }
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .padding(.vertical, Theme.Spacing.standard)
        }
        .scrollDismissesKeyboard(.interactively)
        // Pinned to the bottom by the anchor rather than driven by a
        // `scrollTo` per chunk: the transcript republishes on every streamed
        // chunk, and a per-chunk scroll request is main-thread work the
        // anchor does for free.
        .defaultScrollAnchor(.bottom)
    }

    /// What an empty conversation says instead of blank space: what the coach
    /// is for, in the coach's register, gone the moment there is a transcript.
    private var opening: some View {
        Text(
            "Ask about your practice — which exercise fits how you slept, "
                + "what your breath test means, where to go next."
        )
        .font(.body)
        .foregroundStyle(Theme.Ink.tertiary)
    }

    /// One turn as prose. The person's words are the small voice and the
    /// coach's the body text, because reading the answers is what the screen
    /// is for.
    @ViewBuilder
    private func row(for turn: ChatTurn) -> some View {
        switch turn.role {
        case .person:
            Text(turn.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Ink.secondary)
        case .coach:
            Text(turn.text)
                .font(.body)
                .foregroundStyle(Theme.Ink.primary)
        }
    }

    private var composer: some View {
        HStack(spacing: Theme.Spacing.close) {
            TextField("Ask the coach", text: $draft, axis: .vertical)
                .lineLimit(1 ... 4)
                .textFieldStyle(.plain)
                .onSubmit(send)
                // The intent note's pattern: clamp as typed, so a long paste
                // can never become a refused request that reads as the
                // network failing.
                .onChange(of: draft) { _, text in
                    if text.count > ChatTurn.maxMessageLength {
                        draft = String(text.prefix(ChatTurn.maxMessageLength))
                    }
                }

            // Disabled while a reply streams — the composer itself stays
            // live, so the next question can be typed over the answer.
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Theme.Accent.brand : Theme.Ink.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.vertical, Theme.Spacing.close)
        .background(Theme.Surface.raised)
    }

    private var canSend: Bool {
        !model.isReplying
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The speak-back toggle: replies are read aloud, sentence by sentence,
    /// while they stream. Off by default — a voice nobody asked for is the
    /// fastest way to make a calm screen embarrassing in public.
    private var speakBackToggle: some View {
        Button {
            model.isSpeakingAloud.toggle()
        } label: {
            Image(systemName: model.isSpeakingAloud ? "speaker.wave.2.fill" : "speaker.slash")
        }
        .accessibilityLabel(model
            .isSpeakingAloud ? "Stop reading replies aloud" : "Read replies aloud")
    }

    private func send() {
        let message = draft
        draft = ""
        model.send(message)
    }
}
