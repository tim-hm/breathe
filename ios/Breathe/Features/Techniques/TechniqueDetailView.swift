import BreatheKit
import BreatheUI
import SwiftUI

/// What a technique is, how long you want to do it for, and the way in.
struct TechniqueDetailView: View {
    let technique: Technique
    let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings
    @State private var cycles: Int
    @State private var started: StartedSession?

    init(technique: Technique, sessions: any SessionRecording) {
        self.technique = technique
        self.sessions = sessions
        // The catalogue's curated count is the starting point; the stepper below
        // is the override, which lives here until there is a profile to keep it.
        _cycles = State(initialValue: technique.recommendedCycles)
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                header
                cycleStrip

                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    Stepper(value: $cycles, in: 1 ... 60) {
                        Text(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
                            .font(.headline)
                    }
                    Text("About \(inWords(timeline.totalDuration)). However many you do is the "
                        + "practice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Cues", selection: $settings.cueMode) {
                    ForEach(SessionCueMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                beginButton
            }
            .padding(Theme.Spacing.standard)
        }
        .navigationTitle(technique.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $started) { session in
            SessionView(model: session.model)
        }
    }

    private var timeline: SessionTimeline {
        SessionTimeline(technique: technique, cycles: cycles)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            GoalBadge(goal: technique.goal)
            Text(technique.summary)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    /// The cycle, spelled out in order. Someone deciding whether they have the
    /// patience for a seven-second hold should be able to see it first.
    private var cycleStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text("One cycle")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: Theme.Spacing.close) {
                ForEach(Array(technique.phases.enumerated()), id: \.offset) { _, phase in
                    Text(shortLabel(for: phase))
                        .font(.caption)
                        .padding(.horizontal, Theme.Spacing.close)
                        .padding(.vertical, Theme.Spacing.tight)
                        .background(technique.goal.accent.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var beginButton: some View {
        Button {
            started = StartedSession(
                model: SessionModel(
                    technique: technique,
                    cycles: cycles,
                    cues: SessionCues(mode: settings.cueMode),
                    recorder: sessions
                )
            )
        } label: {
            Text("Begin")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.close)
        }
        .buttonStyle(.borderedProminent)
        .tint(technique.goal.accent)
    }

    /// "In 1.5s" — short enough to sit four across a phone, and precise enough
    /// for the physiological sigh's sub-second sip of air.
    private func shortLabel(for phase: Phase) -> String {
        let name = switch phase.kind {
        case .inhale: "In"
        case .exhale: "Out"
        case .holdIn, .holdOut: "Hold"
        }
        let seconds = phase.duration.seconds
            .formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(name) \(seconds)s"
    }

    private func inWords(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}

/// Wraps the model so `fullScreenCover(item:)` has something `Identifiable` to
/// present. The identity is the presentation's, not the session's — a new tap on
/// Begin is a new session, and this is what makes that unambiguous.
private struct StartedSession: Identifiable {
    let id = UUID()
    let model: SessionModel
}
