import BreatheKit
import BreatheUI
import SwiftUI

/// One schedule's details: the technique, the time, the days.
///
/// The same sheet adds and edits — a nil `schedule` starts a draft with
/// sensible defaults (8 am, weekdays, the catalogue's first technique) so the
/// fastest path from "Add" to a working reminder is picking a technique and
/// tapping Save.
struct ScheduleEditorView: View {
    /// nil when adding.
    let schedule: Schedule?
    let catalogue: TechniqueListModel
    let onSave: (Schedule) -> Void
    /// nil when adding — there is nothing to delete yet.
    let onDelete: (() -> Void)?

    @State private var techniqueSlug: String?
    @State private var time: Date
    @State private var weekdays: Set<Weekday>

    @Environment(\.dismiss) private var dismiss

    init(
        schedule: Schedule?,
        catalogue: TechniqueListModel,
        onSave: @escaping (Schedule) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.schedule = schedule
        self.catalogue = catalogue
        self.onSave = onSave
        self.onDelete = onDelete

        _techniqueSlug = State(wrappedValue: schedule?.techniqueSlug)
        _weekdays = State(wrappedValue: schedule?.weekdays ?? Weekday.weekdays)
        _time = State(wrappedValue: Calendar.current.date(
            from: DateComponents(hour: schedule?.hour ?? 8, minute: schedule?.minute ?? 0)
        ) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    techniquePicker
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                } header: {
                    Text("What and when")
                }
                .listRowBackground(Theme.Surface.raised)

                Section {
                    dayToggles
                } header: {
                    Text("Days")
                } footer: {
                    Text("Rings as a notification on each selected day.")
                }
                .listRowBackground(Theme.Surface.raised)
            }
            .scrollContentBackground(.hidden)
            .paletteGround()
            .navigationTitle(schedule == nil ? "New schedule" : "Edit schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let built {
                            onSave(built)
                        }
                        dismiss()
                    }
                    .disabled(built == nil)
                }
                if let onDelete {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete schedule", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        .foregroundStyle(Theme.Accent.caution)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var techniquePicker: some View {
        switch catalogue.state {
        case let .loaded(techniques) where !techniques.isEmpty:
            Picker("Technique", selection: $techniqueSlug) {
                ForEach(techniques) { technique in
                    Text(technique.name).tag(String?.some(technique.slug))
                }
            }
            // Settled here rather than defaulted in init, because the
            // catalogue may still be loading when the sheet opens.
            .task {
                if techniqueSlug == nil {
                    techniqueSlug = techniques.first?.slug
                }
            }
        default:
            LabeledContent("Technique") {
                Text("Waiting for the catalogue…")
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
    }

    /// The week as a row of round toggles, in this locale's day order.
    private var dayToggles: some View {
        HStack(spacing: Theme.Spacing.close) {
            ForEach(Weekday.inLocalOrder) { day in
                let isOn = weekdays.contains(day)
                Button {
                    if isOn {
                        weekdays.remove(day)
                    } else {
                        weekdays.insert(day)
                    }
                } label: {
                    Text(day.shortName)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.close)
                        .background(
                            isOn ? Theme.Accent.brand.opacity(0.18) : Theme.Surface.ground,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                isOn ? Theme.Accent.brand : Theme.Surface.line
                            )
                        )
                        .foregroundStyle(isOn ? Theme.Accent.brand : Theme.Ink.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    /// The schedule as the form currently describes it, or nil while it is
    /// not yet a real appointment — no technique, or no days to ring on.
    private var built: Schedule? {
        guard let techniqueSlug,
              case let .loaded(techniques) = catalogue.state,
              let technique = techniques.first(where: { $0.slug == techniqueSlug }),
              !weekdays.isEmpty
        else {
            return nil
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Schedule(
            id: schedule?.id ?? UUID(),
            techniqueSlug: technique.slug,
            techniqueName: technique.name,
            hour: components.hour ?? 8,
            minute: components.minute ?? 0,
            weekdays: weekdays,
            isEnabled: schedule?.isEnabled ?? true
        )
    }
}
