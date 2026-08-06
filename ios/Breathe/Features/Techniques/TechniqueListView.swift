import BreatheKit
import BreatheUI
import SwiftUI

struct TechniqueListView: View {
    @State private var model: TechniqueListModel

    /// Handed down like everything else from the composition root, and held for
    /// the life of the app: the basics are seeded reference data, so the model
    /// keeps them across pushes of the screen rather than refetching.
    private let foundations: FoundationsModel

    /// Handed down from the composition root and passed to each session, so
    /// every session in the app writes to the one store.
    private let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings

    /// Recorded history, oldest first, feeding the hero card. Refreshed on
    /// appear as well as on load, because a session finished on the pushed
    /// detail screen has changed what "begin again" should offer by the time
    /// the person pops back.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?

    init(
        model: TechniqueListModel,
        foundations: FoundationsModel,
        sessions: any SessionRecording
    ) {
        _model = State(wrappedValue: model)
        self.foundations = foundations
        self.sessions = sessions
    }

    var body: some View {
        NavigationStack {
            content
                .paletteGround()
                .navigationTitle("Breathe")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("The basics") {
                            FoundationsView(model: foundations)
                        }
                    }
                }
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
        }
        .task {
            await model.load()
            history = await sessions.recordedSessions()
        }
        .onAppear {
            Task { history = await sessions.recordedSessions() }
        }
        .fullScreenCover(item: $started) { session in
            SessionView(model: session.model)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            List {
                if let suggestion = suggestion(from: techniques) {
                    heroSection(for: suggestion)
                }

                ForEach(goals(in: techniques), id: \.self) { goal in
                    Section {
                        ForEach(techniques.filter { $0.goal == goal }) { technique in
                            NavigationLink(value: technique) {
                                TechniqueRow(technique: technique)
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(goal.intent)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.Ink.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't reach the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await model.load() }
                }
            }
        }
    }

    private func heroSection(for suggestion: HomeSuggestion) -> some View {
        // Dialled here for the same reason the detail screen dials before
        // Begin: the card's shape line and the session it starts must both
        // describe what will actually play.
        let dialled = suggestion.technique
            .dialled(with: settings.overrides(for: suggestion.technique))

        return Section {
            HeroCard(prompt: suggestion.prompt, technique: dialled) {
                started = StartedSession(
                    model: SessionModel(
                        technique: dialled,
                        cues: SessionCues(mode: settings.cueMode),
                        recorder: sessions
                    )
                )
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func suggestion(from techniques: [Technique]) -> HomeSuggestion? {
        HomeSuggestion.make(
            techniques: techniques,
            history: history,
            hour: Calendar.current.component(.hour, from: .now)
        )
    }

    /// The goals present in the catalogue, in the fixed calm-first order of
    /// the enum — stable across loads, so sections never reshuffle under a
    /// person who has learned where sleep lives.
    private func goals(in techniques: [Technique]) -> [TechniqueGoal] {
        TechniqueGoal.allCases.filter { goal in
            techniques.contains { $0.goal == goal }
        }
    }
}

/// The one suggestion above the catalogue: the person's last exercise, or the
/// time of day's. One Begin on it starts the session directly — the card is a
/// shortcut past the detail screen, whose dials stay a tap away in the list.
private struct HeroCard: View {
    let prompt: String
    /// Already dialled by the caller.
    let technique: Technique
    let begin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(prompt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(technique.goal.accent)

            Text(technique.name)
                .font(.title2.weight(.semibold))

            Text("\(technique.shapeDescription) · about \(inWords(technique.plannedDuration))")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)

            Button(action: begin) {
                Text("Begin")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.close)
                    // The ground, so the label inverts with the fill — same
                    // rationale as the detail screen's Begin.
                    .foregroundStyle(Theme.Surface.ground)
            }
            .buttonStyle(.borderedProminent)
            .tint(technique.goal.accent)
        }
        .padding(Theme.Spacing.standard)
        .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func inWords(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}

private struct TechniqueRow: View {
    let technique: Technique

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(technique.name)
                .font(.headline)

            Text(technique.summary)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)

            Text(technique.shapeDescription)
                .font(.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .padding(.vertical, Theme.Spacing.close)
    }
}

private extension Technique {
    /// "8 cycles · 16s each", or "3 rounds · you end the holds". The shape of
    /// the technique at a glance, which is what someone choosing between nine of
    /// them actually needs — and the staged ones are a different proposition
    /// from the cyclic ones, so they say so.
    var shapeDescription: String {
        guard !isStaged, let stage = stages.first else {
            let unit = recommendedRounds == 1 ? "round" : "rounds"
            return hasOpenEndedStage
                ? "\(recommendedRounds) \(unit) · you end the holds"
                : "\(recommendedRounds) \(unit) · \(stages.count) stages"
        }

        let seconds = stage.cycleDuration.components.seconds
        return "\(stage.cycles) cycles · \(seconds)s each"
    }
}

/// Wraps the model so `fullScreenCover(item:)` has something `Identifiable` to
/// present. The identity is the presentation's, not the session's — a new tap on
/// Begin is a new session, and this is what makes that unambiguous.
private struct StartedSession: Identifiable {
    let id = UUID()
    let model: SessionModel
}
