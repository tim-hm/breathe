import BreatheKit
import BreatheUI
import SwiftUI

/// The app's few dials, and the place future ones land: reminders (M7) and
/// the subscription (M8) get sections here rather than new chrome.
struct SettingsView: View {
    @Environment(SessionSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
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
}
