import SwiftUI

/// One switch, and deliberately nothing else.
///
/// Everything else the phone lets somebody set — appearance, guidance level,
/// per-technique dials, reminders — is a decision made sitting down, and the
/// wrist plays whatever was decided there. Haptics are the exception because the
/// answer changes with the room you are in, which is exactly the kind of thing
/// you change from your wrist.
///
/// No About row, no version string: a screen padded out with things that are not
/// settings is worse than a short one.
struct SettingsView: View {
    @Environment(WatchSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Toggle("Haptics", isOn: $settings.playsHaptics)
                .accessibilityHint("Taps at each phase of the breath")
        }
        .navigationTitle("Settings")
    }
}
