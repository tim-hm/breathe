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
    /// The exercises this person wrote. Beside the catalogue rather than folded
    /// into it: two services, two loads, and only one of them needs an identity.
    let own: UserTechniqueModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel

    /// Lent by the chrome — see `AppChrome` for why it holds the aim.
    let goal: Binding<TechniqueGoal?>

    var homeRoot: some View {
        HomeView(model: catalogue, sessions: sessions, goal: goal)
    }

    var exercisesRoot: some View {
        TechniqueListView(model: catalogue, own: own, sessions: sessions)
    }

    var coachRoot: some View {
        CoachRootView()
    }

    var journeyRoot: some View {
        JourneyView(
            model: journey,
            profiles: profiles,
            catalogue: catalogue,
            foundations: foundations
        )
    }
}
