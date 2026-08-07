import OndKit
import SwiftUI

/// The screens the chrome shows, built from the composition root's models.
///
/// One builder rather than the expressions inline, so `AppChrome` is about how
/// the roots are presented and this is about what they are made of — the two
/// change for different reasons.
///
/// Isolated because building a view is: every screen here holds a `@MainActor`
/// model, and a nonisolated builder would be constructing them from nowhere in
/// particular.
@MainActor
struct AppRoots {
    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel
    let schedules: ScheduleStore

    var homeRoot: some View {
        HomeView(model: catalogue, sessions: sessions)
    }

    var exercisesRoot: some View {
        TechniqueListView(model: catalogue, sessions: sessions)
    }

    var journeyRoot: some View {
        JourneyView(
            model: journey,
            profiles: profiles,
            catalogue: catalogue,
            foundations: foundations
        )
    }

    /// Settings, with no `onDone`: it is a root behind a word like any other,
    /// not a sheet that has to offer its own way out.
    var settingsRoot: some View {
        SettingsView(schedules: schedules, catalogue: catalogue)
    }
}
