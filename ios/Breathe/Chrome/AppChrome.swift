import BreatheKit
import SwiftUI

/// The app's chrome, and the only thing `BreatheApp` puts on screen.
///
/// It exists because the chrome is under evaluation. A debug build picks a
/// navigation style and a home style at runtime from the design lab in
/// Settings; everything that differs between them lives here and in `Chrome/`,
/// so the screens themselves stay one implementation and the losing treatments
/// are deleted rather than untangled. A release build has no lab and no
/// selection to make: it renders the baseline.
///
/// The Settings sheet is owned here rather than by the screens that open it.
/// Three of the four styles have no Settings tab, and a sheet per screen would
/// be three presentations of one screen that could each be open at once.
struct AppChrome: View {
    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel
    let schedules: ScheduleStore

    #if DEBUG
        @State private var variants = DesignVariants()
    #endif

    @State private var isShowingSettings = false

    var body: some View {
        #if DEBUG
            chrome.environment(variants)
        #else
            chrome
        #endif
    }

    private var chrome: some View {
        styled
            .sheet(isPresented: $isShowingSettings) {
                roots.settingsRoot { isShowingSettings = false }
            }
    }

    @ViewBuilder
    private var styled: some View {
        switch navigation {
        case .fiveTabs: FiveTabChrome(roots: roots)
        case .threeTabs: ThreeTabChrome(roots: roots)
        case .threeWords: WordBarChrome(roots: roots, presentation: .bar)
        case .wordRow: WordBarChrome(roots: roots, presentation: .bare)
        }
    }

    private var roots: AppRoots {
        AppRoots(
            style: navigation,
            homeStyle: homeStyle,
            catalogue: catalogue,
            sessions: sessions,
            journey: journey,
            profiles: profiles,
            foundations: foundations,
            schedules: schedules,
            showSettings: navigation.hasFiveTabs ? nil : { isShowingSettings = true }
        )
    }

    #if DEBUG
        private var navigation: NavigationStyle {
            variants.navigation
        }

        private var homeStyle: HomeStyle {
            variants.home
        }
    #else
        private var navigation: NavigationStyle {
            .fiveTabs
        }

        private var homeStyle: HomeStyle {
            .current
        }
    #endif
}
