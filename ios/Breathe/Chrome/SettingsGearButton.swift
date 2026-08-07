import BreatheUI
import SwiftUI

/// The way to Settings from a chrome that has no tab for it.
///
/// Quiet on purpose — it is the least important thing on any screen it appears
/// on — but never quieter than the ink scale's measured values allow, and never
/// smaller than 44pt however small the glyph is drawn.
struct SettingsGearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
    }
}
