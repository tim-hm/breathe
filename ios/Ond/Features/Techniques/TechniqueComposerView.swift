import OndKit
import OndStyle
import OndUI
import SwiftUI

/// Where somebody builds their own exercise: a pattern of breaths, how many
/// times to repeat it, and what to call it.
///
/// One stage, deliberately. The contract carries a stage list because the
/// catalogue needs one, but a single stage repeated in cycles is what somebody
/// writing down the rhythm that works for them actually means — and with one
/// stage a round and a cycle are the same number said twice, so only cycles are
/// offered. An edit leaves any further stages the draft happens to carry
/// untouched rather than dropping them.
///
/// Every control is bounded by `AuthoringLimits`, which comes from the server:
/// the durations are the catalogue's own seeded ranges, so a dial here cannot
/// reach a breath the seeded evidence does not support. The server checks the
/// same values again — this screen exists so that nobody is told no.
struct TechniqueComposerView: View {
    let model: UserTechniqueModel
    let limits: AuthoringLimits

    /// The exercise being edited, or nil when composing a new one. Also what
    /// decides whether saving creates or replaces.
    let editing: Technique?

    @Environment(\.dismiss) private var dismiss

    @State private var draft: TechniqueDraft
    @State private var refusal: String?
    @State private var isSaving = false

    init(model: UserTechniqueModel, limits: AuthoringLimits, editing: Technique? = nil) {
        self.model = model
        self.limits = limits
        self.editing = editing
        _draft = State(
            initialValue: editing.map(TechniqueDraft.init(editing:))
                ?? Self.opening(within: limits)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                patternSection
                lengthSection

                if let refusal {
                    Section {
                        Text(refusal)
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New exercise" : "Edit exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isComplete || isSaving)
                }
            }
            .tint(draft.goal.accent)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.name)
                .onChange(of: draft.name) { _, name in
                    // Trimmed on save, so the ceiling counts what the server
                    // will: a name that is only over the limit because of
                    // trailing spaces should not block the button.
                    draft.name = String(name.prefix(limits.maxNameChars))
                }

            Picker("For when you want to", selection: $draft.goal) {
                ForEach(TechniqueGoal.allCases, id: \.self) { goal in
                    Text(goal.intentObject).tag(goal)
                }
            }
        } footer: {
            Text("The name is yours — it is what the exercise is called everywhere in the app.")
        }
    }

    /// The breaths, in the order they are taken.
    ///
    /// A `List` row per phase rather than a canvas: what is being authored is an
    /// ordered list of two facts each, and every gesture for reordering and
    /// removing one already exists on a row.
    private var patternSection: some View {
        Section {
            ForEach($draft.stages[0].phases) { $phase in
                phaseRow($phase)
            }
            .onDelete { offsets in
                // Never to nothing: an exercise with no breaths in it is not a
                // shorter exercise.
                guard draft.stages[0].phases.count > offsets.count else { return }
                draft.stages[0].phases.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                draft.stages[0].phases.move(fromOffsets: source, toOffset: destination)
            }

            if draft.stages[0].phases.count < limits.maxPhasesPerStage {
                addPhaseMenu
            }
        } header: {
            Text("One cycle")
        } footer: {
            Text(
                "\(draft.stages[0].phases.count) of \(limits.maxPhasesPerStage) breaths. "
                    + "Swipe a row to remove it."
            )
        }
    }

    private var addPhaseMenu: some View {
        Menu("Add a breath") {
            ForEach(limits.phases, id: \.kind) { limit in
                // The spoken form rather than the on-screen one, because this
                // is the one place both holds are adjacent and `instruction`
                // renders them as the same word twice.
                Button(limit.kind.spokenInstruction) {
                    draft.stages[0].phases.append(
                        DraftPhase(kind: limit.kind, duration: Self.opening(of: limit.range))
                    )
                }
            }
        }
    }

    private func phaseRow(_ phase: Binding<DraftPhase>) -> some View {
        let range = limits.range(for: phase.wrappedValue.kind)

        return Stepper(
            value: seconds(of: phase),
            in: (range?.lowerBound.seconds ?? 0) ... (range?.upperBound.seconds ?? 0),
            step: 0.5
        ) {
            LabeledContent(
                phase.wrappedValue.kind.spokenInstruction,
                value: "\(phase.wrappedValue.duration.inSeconds)s"
            )
        }
        // A kind with no seeded range has nothing safe to dial it to, which is
        // the server refusing it rather than this screen deciding.
        .disabled(range == nil)
    }

    private var lengthSection: some View {
        Section {
            Stepper(value: $draft.stages[0].cycles, in: limits.cycleRange) {
                Text(draft.stages[0].cycles == 1 ? "1 cycle" : "\(draft.stages[0].cycles) cycles")
            }
        } footer: {
            Text("About \(inWords(draft.plannedDuration)).")
        }
    }

    /// Whether there is an exercise here at all — a name and at least one
    /// breath. The ranges cannot be broken by the controls above, so nothing
    /// else needs checking before the server sees it.
    private var isComplete: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.stages[0].phases.isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        var submitted = limits.clamping(draft)
        submitted.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await model.save(submitted, replacing: editing?.id)
            dismiss()
        } catch {
            // The server's own words. It names the phase it objected to, which
            // is the one thing a generic failure could not.
            refusal = error.localizedDescription
        }
    }

    /// Seconds rather than milliseconds, because `Stepper` steps in the units it
    /// displays and half a second is the smallest move worth making by hand.
    private func seconds(of phase: Binding<DraftPhase>) -> Binding<Double> {
        Binding(
            get: { phase.wrappedValue.duration.seconds },
            set: { phase.wrappedValue.duration = .milliseconds(Int(($0 * 1000).rounded())) }
        )
    }

    /// Where a phase's dial starts: the middle of its safe range, rounded to the
    /// half-second the stepper moves in, so the first tap is a small change
    /// rather than a correction of an extreme.
    private static func opening(of range: ClosedRange<Duration>) -> Duration {
        let middle = (range.lowerBound.seconds + range.upperBound.seconds) / 2
        return .milliseconds(Int((middle * 2).rounded() / 2 * 1000))
    }

    /// The exercise a blank composer opens on: one breath in, one out, ten
    /// times. The simplest thing that is already a real exercise, so the first
    /// thing somebody does is adjust rather than assemble.
    private static func opening(within limits: AuthoringLimits) -> TechniqueDraft {
        let phases = [PhaseKind.inhale, .exhale].compactMap { kind -> DraftPhase? in
            guard let range = limits.range(for: kind) else { return nil }
            return DraftPhase(kind: kind, duration: opening(of: range))
        }

        return TechniqueDraft(
            name: "",
            goal: .calm,
            stages: [DraftStage(phases: phases, cycles: 10)]
        )
    }

    private func inWords(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}
