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

    @Environment(PlusStore.self) private var plus

    @State private var isShowingPaywall = false

    var body: some View {
        @Bindable var settings = settings
        // Derived once per pass and handed down: `dialled` walks the stored
        // preferences and rebuilds every stage, which is not work to repeat for
        // each section of one screen.
        let dialled = technique.dialled(with: settings.overrides(for: technique))

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                header
                BreathRhythmChart(technique: dialled)
                SafetyNote(technique: technique)
                WhyThisWorksView(techniqueSlug: technique.slug)
                sessionShape(of: dialled)
                lengthControl(of: dialled)
                advanced(of: dialled)
                beginButton(playing: dialled)
            }
            .padding(Theme.Spacing.standard)
        }
        .paletteGround()
        .navigationTitle(technique.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(highlighting: technique.requires)
        }
        .fullScreenCover(item: $started) { session in
            SessionView(model: session.model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            GoalBadge(goal: technique.goal)
            Text(technique.summary)
                .font(.body)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// The session, spelled out stage by stage. Someone deciding whether they
    /// have the patience for a seven-second hold should be able to see it first.
    private func sessionShape(of dialled: Technique) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            ForEach(Array(dialled.stages.enumerated()), id: \.offset) { index, stage in
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
    private func lengthControl(of dialled: Technique) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            if technique.isStaged {
                Stepper(value: roundsBinding, in: TechniqueOverrides.roundRange) {
                    Text(dialled.recommendedRounds == 1 ? "1 round"
                        : "\(dialled.recommendedRounds) rounds")
                        .font(.headline)
                }
            } else {
                cyclesStepper(of: dialled, stage: 0).font(.headline)
            }

            Text(lengthDescription(of: dialled))
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// Simple by default, deep on demand: the dials are real, they are bounded
    /// by the ranges the catalogue seeds, and they are one tap out of the way.
    private func advanced(of dialled: Technique) -> some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                ForEach(Array(dialled.stages.enumerated()), id: \.offset) { index, stage in
                    VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                        if technique.isStaged {
                            Text(stageTitle(index: index, stage: stage))
                                .font(.subheadline.weight(.semibold))
                        }

                        ForEach(
                            Array(stage.phases.enumerated()),
                            id: \.offset
                        ) { phaseIndex, phase in
                            phaseDial(stage: index, phase: phaseIndex, of: phase)
                        }

                        if technique.isStaged, !stage.openEnded {
                            cyclesStepper(of: dialled, stage: index)
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

    private func cyclesStepper(of dialled: Technique, stage: Int) -> some View {
        let cycles = dialled.stages[stage].cycles
        return Stepper(value: cyclesBinding(stage: stage), in: TechniqueOverrides.cycleRange) {
            Text(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
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
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// Begin, or the offer that has to come first.
    ///
    /// The second gate, and deliberately not the only one: the list opens the
    /// paywall instead of navigating here, but home's wheel and a watch handoff
    /// both reach this screen directly. A person who arrives on a locked
    /// technique should read about it — that is what the catalogue is for — and
    /// meet the offer at the moment they try to breathe it.
    private func beginButton(playing dialled: Technique) -> some View {
        Button {
            guard technique.isUnlocked(for: plus.tier) else {
                isShowingPaywall = true
                return
            }

            started = StartedSession(
                model: SessionModel(
                    technique: dialled,
                    cues: SessionCues(mode: settings.cueMode, strength: settings.hapticStrength),
                    recorder: sessions
                )
            )
        } label: {
            Text(technique.isUnlocked(for: plus.tier) ? "Begin" : "Unlock to breathe this")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.close)
                // The ground, so the label inverts with the fill: an accent is
                // dark on white and light on near-black, and a prominent button
                // that kept white text would be unreadable in one of the two.
                .foregroundStyle(Theme.Surface.ground)
        }
        .buttonStyle(.borderedProminent)
        .tint(technique.goal.accent)
    }

    /// The person's own settings, or the catalogue's where they have none —
    /// resolved through the technique, so a preference whose shape no longer
    /// matches it can never be indexed by the dials below.
    private var stored: TechniqueOverrides {
        technique.resolving(settings.overrides(for: technique))
    }

    private func update(_ change: (inout TechniqueOverrides) -> Void) {
        var overrides = stored
        change(&overrides)
        settings.setOverrides(overrides, for: technique)
    }

    private var roundsBinding: Binding<Int> {
        Binding(get: { stored.rounds }, set: { rounds in update { $0.rounds = rounds } })
    }

    private func cyclesBinding(stage: Int) -> Binding<Int> {
        Binding(
            get: { stored.stageCycles[stage] },
            set: { cycles in update { $0.stageCycles[stage] = cycles } }
        )
    }

    /// Seconds rather than milliseconds, because `Stepper` steps in the units it
    /// displays and half a second is the smallest move worth making by hand.
    private func durationBinding(stage: Int, phase: Int) -> Binding<Double> {
        Binding(
            get: { Double(stored.phaseDurationsMs[stage][phase]) / 1000 },
            set: { seconds in
                update { $0.phaseDurationsMs[stage][phase] = Int((seconds * 1000).rounded()) }
            }
        )
    }

    private func stageTitle(index: Int, stage: Stage) -> String {
        guard technique.isStaged else { return "One cycle" }

        let position = "Stage \(index + 1)"
        if stage.openEnded {
            return "\(position) — you end this one"
        }
        return stage.cycles == 1 ? position : "\(position) — \(stage.cycles) cycles"
    }

    private func lengthDescription(of dialled: Technique) -> String {
        let planned = inWords(dialled.plannedDuration)

        if technique.hasOpenEndedStage {
            return "Around \(planned), depending on how long your holds run. "
                + "However many rounds you do is the practice."
        }
        return "About \(planned). However many you do is the practice."
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
