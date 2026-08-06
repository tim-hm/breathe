import BreatheKit
import BreatheUI
import SwiftUI

/// What a technique is, what it asks of you, how long you want to do it for,
/// and the way in.
struct TechniqueDetailView: View {
    let technique: Technique
    let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings
    @State private var started: StartedSession?

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                header
                SafetyNote(technique: technique)
                sessionShape
                lengthControl
                advanced

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

    // MARK: - What the person is choosing

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            GoalBadge(goal: technique.goal)
            Text(technique.summary)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    /// The session, spelled out stage by stage. Someone deciding whether they
    /// have the patience for a seven-second hold should be able to see it first.
    private var sessionShape: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            ForEach(Array(playedStages.enumerated()), id: \.offset) { index, stage in
                VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                    Text(stageTitle(index: index, stage: stage))
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: Theme.Spacing.close) {
                        ForEach(Array(stage.phases.enumerated()), id: \.offset) { _, phase in
                            Text(shortLabel(for: phase, openEnded: stage.openEnded))
                                .font(.caption)
                                .padding(.horizontal, Theme.Spacing.close)
                                .padding(.vertical, Theme.Spacing.tight)
                                .background(technique.goal.accent.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    /// One control, chosen by shape: a cyclic technique is dialled in cycles, a
    /// staged one in rounds. The other lives under Advanced, where someone who
    /// wants both can find it.
    private var lengthControl: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            if technique.stages.count > 1 {
                Stepper(value: roundsBinding, in: TechniqueOverrides.roundRange) {
                    Text(dialled.rounds == 1 ? "1 round" : "\(dialled.rounds) rounds")
                        .font(.headline)
                }
            } else {
                let cycles = dialled.stageCycles[0]
                Stepper(value: cyclesBinding(stage: 0), in: TechniqueOverrides.cycleRange) {
                    Text(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
                        .font(.headline)
                }
            }

            Text(lengthDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced

    /// Simple by default, deep on demand: the dials are real, they are bounded
    /// by the ranges the catalogue seeds, and they are one tap out of the way.
    private var advanced: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                ForEach(Array(playedStages.enumerated()), id: \.offset) { index, stage in
                    VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                        if technique.stages.count > 1 {
                            Text(stageTitle(index: index, stage: stage))
                                .font(.subheadline.weight(.semibold))
                        }

                        ForEach(
                            Array(stage.phases.enumerated()),
                            id: \.offset
                        ) { phaseIndex, phase in
                            phaseDial(stage: index, phase: phaseIndex, of: phase)
                        }

                        if technique.stages.count > 1, !stage.openEnded {
                            Stepper(
                                value: cyclesBinding(stage: index),
                                in: TechniqueOverrides.cycleRange
                            ) {
                                Text("\(stage.cycles) cycles")
                            }
                        }
                    }
                }

                Button("Back to the suggested settings") {
                    settings.setOverrides(nil, for: technique)
                }
                .font(.footnote)
                .disabled(settings.overrides(for: technique) == nil)
            }
            .padding(.top, Theme.Spacing.close)
        }
        .tint(technique.goal.accent)
    }

    @ViewBuilder
    private func phaseDial(stage: Int, phase index: Int, of phase: Phase) -> some View {
        if phase.isAdjustable {
            Stepper(
                value: durationBinding(stage: stage, phase: index),
                in: phase.range.lowerBound.seconds ... phase.range.upperBound.seconds,
                step: 0.5
            ) {
                LabeledContent(phase.kind.instruction, value: inSeconds(phase.duration))
            }
        } else {
            // A hold the person ends has no dial, and a disabled stepper would
            // invite them to look for one.
            LabeledContent(phase.kind.instruction, value: "you decide")
                .foregroundStyle(.secondary)
        }
    }

    private var beginButton: some View {
        Button {
            started = StartedSession(
                model: SessionModel(
                    technique: technique,
                    stages: playedStages,
                    rounds: dialled.rounds,
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

    // MARK: - The dialled technique

    /// The person's own settings, or the catalogue's where they have none.
    /// Read through `settings` on every access rather than copied into `@State`:
    /// one source of truth, and every turn of a dial is already saved.
    private var dialled: TechniqueOverrides {
        settings.overrides(for: technique) ?? technique.curatedOverrides
    }

    private var playedStages: [Stage] {
        technique.stages(applying: dialled)
    }

    private func update(_ change: (inout TechniqueOverrides) -> Void) {
        var overrides = dialled
        change(&overrides)
        settings.setOverrides(overrides, for: technique)
    }

    private var roundsBinding: Binding<Int> {
        Binding(get: { dialled.rounds }, set: { rounds in update { $0.rounds = rounds } })
    }

    private func cyclesBinding(stage: Int) -> Binding<Int> {
        Binding(
            get: { dialled.stageCycles[stage] },
            set: { cycles in update { $0.stageCycles[stage] = cycles } }
        )
    }

    /// Seconds rather than milliseconds, because `Stepper` steps in the units it
    /// displays and half a second is the smallest move worth making by hand.
    private func durationBinding(stage: Int, phase: Int) -> Binding<Double> {
        Binding(
            get: { Double(dialled.phaseDurationsMs[stage][phase]) / 1000 },
            set: { seconds in
                update { $0.phaseDurationsMs[stage][phase] = Int((seconds * 1000).rounded()) }
            }
        )
    }

    // MARK: - Copy

    private func stageTitle(index: Int, stage: Stage) -> String {
        guard technique.stages.count > 1 else { return "One cycle" }

        let position = "Stage \(index + 1)"
        if stage.openEnded {
            return "\(position) — you end this one"
        }
        return stage.cycles == 1 ? position : "\(position) — \(stage.cycles) cycles"
    }

    private var lengthDescription: String {
        let planned = SessionTimeline(stages: playedStages, rounds: dialled.rounds).totalDuration

        if technique.hasOpenEndedStage {
            return "Around \(inWords(planned)), depending on how long your holds run. "
                + "However many rounds you do is the practice."
        }
        return "About \(inWords(planned)). However many you do is the practice."
    }

    /// "In 1.5s" — short enough to sit four across a phone, and precise enough
    /// for the physiological sigh's sub-second sip of air.
    private func shortLabel(for phase: Phase, openEnded: Bool) -> String {
        let name = switch phase.kind {
        case .inhale: "In"
        case .exhale: "Out"
        case .holdIn, .holdOut: "Hold"
        }
        return openEnded ? name : "\(name) \(inSeconds(phase.duration))"
    }

    private func inSeconds(_ duration: Duration) -> String {
        let seconds = duration.seconds.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(seconds)s"
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
