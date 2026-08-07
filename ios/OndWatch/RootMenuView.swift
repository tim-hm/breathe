import OndKit
import SwiftUI

/// The watch app's front door: three rows and nothing else.
///
/// A menu rather than the catalogue itself, which is what this screen used to
/// be. Opening straight into a carousel meant every launch landed on a decision,
/// and it left the other two surfaces to be found behind a glyph at the edge.
/// One tap to a screen that does one thing is what a watch app is.
struct RootMenuView: View {
    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel

    var body: some View {
        List {
            NavigationLink {
                TechniqueCarouselView(model: catalogue, sessions: sessions, journey: journey)
            } label: {
                Label("Exercises", systemImage: "figure.mind.and.body")
            }

            NavigationLink {
                JourneyView(model: journey)
            } label: {
                // The phone's Journey tab icon, so the same door has the same
                // handle on both devices.
                Label("Journey", systemImage: "clock.arrow.circlepath")
            }

            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .navigationTitle("önd")
    }
}
