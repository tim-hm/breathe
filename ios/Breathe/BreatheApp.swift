import BreatheKit
import SwiftUI

@main
struct BreatheApp: App {
    /// Built once, at the composition root, and handed down. Views receive a
    /// `TechniqueReading` rather than constructing their own, so a preview or a
    /// test can substitute one without touching the network.
    private let techniques: any TechniqueReading = TechniqueRepository(
        baseURL: AppConfiguration.apiBaseURL
    )

    /// One store for the whole app: every session ends up in the same file, and
    /// M5's sync has one place to drain.
    private let sessions: any SessionRecording = FileSessionStore()

    /// In the environment rather than passed down, because the cue picker on the
    /// detail screen and the session that reads the setting are not adjacent.
    @State private var settings = SessionSettings()

    var body: some Scene {
        WindowGroup {
            TechniqueListView(
                model: TechniqueListModel(techniques: techniques),
                sessions: sessions
            )
            .environment(settings)
        }
    }
}
