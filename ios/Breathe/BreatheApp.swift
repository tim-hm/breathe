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

    var body: some Scene {
        WindowGroup {
            TechniqueListView(model: TechniqueListModel(techniques: techniques))
        }
    }
}
