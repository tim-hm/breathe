import BreatheKit
import SwiftUI

/// The screens every chrome shows, built from the composition root's models.
///
/// One builder rather than five expressions per chrome: the navigation styles
/// are meant to differ in how the roots are presented and in nothing else, and a
/// chrome free to construct its own `HomeView` is a chrome free to drift from
/// the others. Two of the roots do change shape — the ones that absorb a tab the
/// chrome had no room for — and `style` is what decides that, once.
///
/// Isolated because building a view is: every screen here holds a `@MainActor`
/// model, and a nonisolated builder would be constructing them from nowhere in
/// particular.
@MainActor
struct AppRoots {
    let style: NavigationStyle
    let homeStyle: HomeStyle

    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel
    let schedules: ScheduleStore

    /// Opens Settings from a chrome with no tab for it. Nil under the five-tab
    /// baseline, which is what keeps a gear off that chrome's screens.
    let showSettings: (() -> Void)?

    @ViewBuilder
    var homeRoot: some View {
        switch homeStyle {
        case .current:
            HomeView(model: catalogue, sessions: sessions, showSettings: showSettings)
        case .minimal:
            MinimalHomeView(model: catalogue, sessions: sessions, showSettings: showSettings)
        }
    }

    var techniquesRoot: some View {
        TechniqueListView(
            model: catalogue,
            sessions: sessions,
            showSettings: showSettings,
            foundations: style.hasFiveTabs ? nil : foundations
        )
    }

    var journeyRoot: some View {
        JourneyView(
            model: journey,
            profiles: profiles,
            catalogue: catalogue,
            showSettings: showSettings
        )
    }

    /// Only ever a tab root, so it brings the stack a pushed copy would get from
    /// whatever pushed it.
    var basicsRoot: some View {
        NavigationStack {
            FoundationsView(model: foundations)
        }
    }

    /// Settings as a tab root when `onDone` is nil, and as a sheet when it is
    /// not — the same screen either way, with the dismissal the presentation
    /// needs.
    func settingsRoot(onDone: (() -> Void)? = nil) -> some View {
        SettingsView(schedules: schedules, catalogue: catalogue, onDone: onDone)
    }
}
