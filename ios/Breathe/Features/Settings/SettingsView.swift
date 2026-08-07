import BreatheKit
import BreatheUI
import SwiftUI

/// The app's few dials, and the place future ones land: the subscription
/// (M8) gets a section here rather than new chrome.
struct SettingsView: View {
    /// Schedules live behind a link here rather than a tab: set once, edited
    /// rarely, and the notification tray is their daily face.
    let schedules: ScheduleStore
    let catalogue: TechniqueListModel

    @Environment(SessionSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
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
        }
    }

    /// "2 active" beside the link — enough to know the feature is in use
    /// without opening it. Disabled schedules deliberately don't count.
    private var scheduleSummary: String {
        let active = schedules.schedules.count(where: \.isEnabled)
        return active == 0 ? "None" : "\(active) active"
    }
}
