import BreatheKit
import BreatheUI
import SwiftUI

/// The app's few dials, plus the reminder schedules and the legal links App
/// Review expects to find outside a paywall.
///
/// The subscription is deliberately not among them. It is offered where the
/// reason to buy is already on screen — a locked technique, or the assistant
/// strip that named one — and a Settings row would be a fifth entry point with
/// no such reason beside it.
struct SettingsView: View {
    /// Schedules live behind a link here rather than a tab: set once, edited
    /// rarely, and the notification tray is their daily face.
    let schedules: ScheduleStore
    let catalogue: TechniqueListModel

    /// Dismisses the screen. Non-nil only where Settings arrived as a sheet
    /// rather than as a tab root, which is the only presentation that needs a
    /// way out of its own.
    var onDone: (() -> Void)?

    @Environment(SessionSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                #if DEBUG
                    DesignLabSection()
                #endif

                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
                .listRowBackground(Theme.Surface.raised)

                Section {
                    NavigationLink {
                        SchedulesView(store: schedules, catalogue: catalogue)
                    } label: {
                        LabeledContent("Schedules") {
                            Text(scheduleSummary)
                        }
                    }
                } footer: {
                    Text("A standing time for a technique — box breathing every "
                        + "weekday at 8, say. iOS asks for notification "
                        + "permission when you set your first one.")
                }
                .listRowBackground(Theme.Surface.raised)

                Section {
                    Picker("Cues", selection: $settings.cueMode) {
                        ForEach(SessionCueMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("Vibration", selection: $settings.hapticStrength) {
                        ForEach(HapticStrength.allCases) { strength in
                            Text(strength.title).tag(strength)
                        }
                    }
                    // Beside Cues rather than folded into it, and dimmed by it:
                    // a strength control under a mode that plays no haptics is
                    // a dial connected to nothing.
                    .disabled(!settings.cueMode.playsHaptics)

                    Picker("Guidance", selection: $settings.guidance) {
                        ForEach(SessionGuidance.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text(
                        "Full guidance keeps the instruction, the countdown, and any "
                            + "hints on screen. Just the visuals leaves the orb to guide "
                            + "you. Safety notes always show."
                    )
                }
                .listRowBackground(Theme.Surface.raised)
            }
            .scrollContentBackground(.hidden)
            .paletteGround()
            .navigationTitle("Settings")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
    }

    /// "2 active" beside the link — enough to know the feature is in use
    /// without opening it. Disabled schedules deliberately don't count.
    private var scheduleSummary: String {
        let active = schedules.schedules.count(where: \.isEnabled)
        return active == 0 ? "None" : "\(active) active"
    }
}
