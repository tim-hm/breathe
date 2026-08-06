import BreatheKit
import BreatheUI
import SwiftUI

/// The standing appointments: which technique, when, and on which days.
///
/// Reached from Settings rather than owning a tab — a schedule is set once and
/// then lives in the notification tray, so the screen is for the occasional
/// edit, not the daily path.
struct SchedulesView: View {
    let store: ScheduleStore
    /// The catalogue the editor picks techniques from — the same shared model
    /// every tab reads, so opening this screen costs no second fetch.
    let catalogue: TechniqueListModel

    /// The schedule being edited, or nil when the editor is closed. Adding is
    /// editing a draft that does not exist in the store yet — one sheet, one
    /// code path.
    @State private var editing: Schedule?
    @State private var isAdding = false

    var body: some View {
        List {
            if store.schedules.isEmpty {
                ContentUnavailableView {
                    Label("No schedules yet", systemImage: "clock.badge")
                } description: {
                    Text("A schedule rings as a notification — box breathing "
                        + "every weekday at 8, or winding down on Sunday nights.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.schedules) { schedule in
                    row(schedule)
                }
                .listRowBackground(Theme.Surface.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .paletteGround()
        .navigationTitle("Schedules")
        .toolbar {
            Button("Add schedule", systemImage: "plus") {
                isAdding = true
            }
        }
        .task { await catalogue.loadIfNeeded() }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(schedule: schedule, catalogue: catalogue) { edited in
                store.update(edited)
            } onDelete: {
                store.remove(schedule)
            }
        }
        .sheet(isPresented: $isAdding) {
            ScheduleEditorView(
                schedule: nil,
                catalogue: catalogue,
                onSave: { store.add($0) },
                onDelete: nil
            )
        }
    }

    private func row(_ schedule: Schedule) -> some View {
        HStack(spacing: Theme.Spacing.standard) {
            Button {
                editing = schedule
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(schedule.techniqueName)
                        .font(.headline)
                        .foregroundStyle(Theme.Ink.primary)
                    Text("\(schedule.timeLabel) · \(schedule.daysLabel)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { store.setEnabled($0, for: schedule) }
                )
            )
            .labelsHidden()
            .tint(Theme.Accent.brand)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.remove(schedule)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
