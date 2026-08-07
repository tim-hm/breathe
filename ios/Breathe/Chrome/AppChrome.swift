import BreatheKit
import BreatheUI
import SwiftUI

/// The app's chrome, and the only thing `BreatheApp` puts on screen: three roots
/// under a row of three words.
///
/// Hand-built rather than a `TabView`: a `Tab` always reserves the image well
/// above its label, so a label-only tab item comes out as a word floating under
/// the space an icon used to occupy. A `ZStack` of the three roots gives back the
/// one thing the `TabView` was providing — every root stays in the hierarchy
/// across a switch, so coming back to a screen lands where it was left.
///
/// The row takes its space from the roots by standing beside them in a `VStack`
/// rather than by insetting their safe area. `safeAreaInset` is the obvious tool
/// and it does not work here: a `NavigationStack` ignores an inset applied from
/// outside it, so every root lays out as though the row were not there and the
/// words land on top of whatever is at the foot of the screen. What that costs is
/// content scrolling *under* the words, which is what this treatment wants
/// anyway — there is no bar and no hairline, and the palette's ground runs to the
/// physical edge, so the whole thing reads as one continuous page.
///
/// Everything that is not a root arrives through the drawer: swiping up on the
/// word row lifts a short sheet of secondary destinations (`ChromeDrawer`),
/// and choosing one dismisses it before the chosen sheet is presented — a
/// sheet cannot present the next sheet itself, so its `onDismiss` is where the
/// routing lives. The Settings sheet stays owned here for the same reason it
/// always was: no root has a Settings tab, and a sheet per screen would be
/// three presentations of one screen that could each be open at once.
struct AppChrome: View {
    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel
    let schedules: ScheduleStore

    @State private var selection: WordTab = .breathe
    @State private var isShowingSettings = false
    @State private var isShowingDrawer = false
    /// What was chosen in the drawer, held across its dismissal: the drawer's
    /// `onDismiss` reads it to present the chosen sheet, then clears it.
    @State private var drawerChoice: DrawerDestination?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                root(.breathe) { roots.homeRoot }
                root(.exercises) { roots.exercisesRoot }
                root(.journey) { roots.journeyRoot }
            }
            row
        }
        // The row stops at the safe area, above the home indicator. The ground
        // carries on past it to the physical edge, so no strip of system
        // background shows under the words.
        .background(Theme.Surface.ground.ignoresSafeArea())
        .sheet(isPresented: $isShowingSettings) {
            roots.settingsRoot { isShowingSettings = false }
        }
        .sheet(isPresented: $isShowingDrawer, onDismiss: routeDrawerChoice) {
            ChromeDrawer { choice in
                drawerChoice = choice
                isShowingDrawer = false
            }
            .presentationDetents([.height(180)])
            // The visual echo of the swipe that opened it, and the one hint
            // the drawer can be dragged back down.
            .presentationDragIndicator(.visible)
        }
    }

    /// Where a drawer choice lands, after the drawer has gone: presenting from
    /// `onDismiss` is the reliable ordering, because one sheet cannot hand
    /// over to the next while it is still up.
    private func routeDrawerChoice() {
        switch drawerChoice {
        case .settings:
            isShowingSettings = true
        case nil:
            break
        }

        drawerChoice = nil
    }

    private var roots: AppRoots {
        AppRoots(
            catalogue: catalogue,
            sessions: sessions,
            journey: journey,
            profiles: profiles,
            foundations: foundations,
            schedules: schedules
        )
    }

    /// One root, kept in the hierarchy whether or not it is the one on screen,
    /// and taken out of the accessibility tree while it is not — without that,
    /// VoiceOver reads three screens stacked on top of each other.
    private func root(_ tab: WordTab, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(WordTab.allCases) { tab in
                word(tab)
            }
        }
        .padding(.top, Theme.Spacing.close)
        .sensoryFeedback(.selection, trigger: selection)
        // Simultaneous so the word buttons keep their taps — a tap has no
        // translation, so it never trips the threshold. The row sits above the
        // bottom safe area, clear of the home indicator's own gesture.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                let h = value.translation.height
                if h < -30, abs(h) > abs(value.translation.width) {
                    isShowingDrawer = true
                }
            }
        )
        // The swipe is invisible to VoiceOver; this is its spoken route in.
        .accessibilityAction(named: Text("More")) { isShowingDrawer = true }
    }

    /// One word, letter-spaced and lowercase, with the whole column beneath it as
    /// its target — three words on one line are small, and a 44pt row is what
    /// keeps them pressable.
    private func word(_ tab: WordTab) -> some View {
        let isSelected = selection == tab

        return Button {
            selection = tab
        } label: {
            VStack(spacing: Theme.Spacing.tight) {
                Text(tab.word)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .kerning(1.6)
                    .foregroundStyle(isSelected ? Theme.Accent.brand : Theme.Ink.tertiary)

                // With no bar behind the words, colour is otherwise the only
                // thing separating the selected one — and colour alone is a
                // signal some people never see.
                Capsule()
                    .fill(isSelected ? Theme.Accent.brand : .clear)
                    .frame(width: 16, height: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The three roots the word row offers.
///
/// Lowercase because that is how they are drawn: the word is the label, and there
/// is no separate display form to keep in step with it.
private enum WordTab: String, CaseIterable, Identifiable {
    case breathe
    case exercises
    case journey

    var id: Self {
        self
    }

    var word: String {
        rawValue
    }
}
