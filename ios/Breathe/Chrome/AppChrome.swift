import BreatheKit
import BreatheUI
import SwiftUI

/// The app's chrome, and the only thing `BreatheApp` puts on screen: the roots
/// over a shelf of words that pulls open.
///
/// Hand-built rather than a `TabView`: a `Tab` always reserves the image well
/// above its label, so a label-only tab item comes out as a word floating under
/// the space an icon used to occupy. A `ZStack` of the roots gives back the one
/// thing the `TabView` was providing — every root stays in the hierarchy across
/// a switch, so coming back to a screen lands where it was left.
///
/// The shelf takes its space from the roots by standing beside them in a
/// `VStack` rather than by insetting their safe area. `safeAreaInset` is the
/// obvious tool and it does not work here: a `NavigationStack` ignores an inset
/// applied from outside it, so every root lays out as though the shelf were not
/// there and the words land on top of whatever is at the foot of the screen.
/// Standing beside them is also what makes the pull honest: the roots give up
/// the height the shelf takes, so an open shelf covers nothing and needs no
/// scrim to keep the content under it from taking taps meant for the words.
///
/// The shelf sits on `Surface.raised`, carried past the bottom safe area to the
/// physical edge. The plain ground would read calmer, but the roots stop dead at
/// the shelf's top edge and with nothing marking that edge a list truncated
/// there looks like it merely ran out of screen. One step off the ground
/// separates the chrome from the content without drawing anything; a hairline is
/// the harder edge of the two and would reintroduce the bar this shelf exists to
/// avoid.
///
/// Everything the chrome can put you on is one of these words, whether or not
/// the shelf has to be open to reach it. `WordTab.secondary` is revealed by the
/// pull and is otherwise selected, underlined, and routed exactly like the three
/// always on show — so growing the chrome is a case, a word, and a root, never a
/// sheet with its own way in and out.
struct AppChrome: View {
    let catalogue: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel
    let schedules: ScheduleStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: WordTab = .breathe
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                root(.breathe) { roots.homeRoot }
                root(.exercises) { roots.exercisesRoot }
                root(.journey) { roots.journeyRoot }
                root(.settings) { roots.settingsRoot }
            }

            shelf
        }
        .background(Theme.Surface.ground.ignoresSafeArea())
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
    /// VoiceOver reads every screen stacked on top of the others.
    private func root(_ tab: WordTab, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }

    private var shelf: some View {
        VStack(spacing: 0) {
            handle

            row(WordTab.primary)

            if isExpanded {
                row(WordTab.secondary)
            }
        }
        .background(Theme.Surface.raised.ignoresSafeArea(edges: .bottom))
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func row(_ tabs: [WordTab]) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                word(tab)
            }
        }
    }

    /// The one hint that the shelf moves, and the only place it can be dragged
    /// from. A drag anywhere else would have to share the space with the words,
    /// and a pull that stays inside a 44pt button fires that button too — so
    /// pulling down on `settings` to close the shelf would select it on the way.
    ///
    /// Tap and drag are one gesture rather than a `Button` carrying a
    /// `simultaneousGesture`: both of those fire on a pull, and the tap's toggle
    /// would undo what the drag just did. That costs the button's accessibility,
    /// so it is declared here by hand — this is the route in for anyone who does
    /// not discover the drag.
    private var handle: some View {
        Capsule()
            .fill(Theme.Ink.tertiary)
            .frame(width: 32, height: 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let height = value.translation.height

                    if abs(height) < 10 {
                        setExpanded(!isExpanded)
                    } else if abs(height) > abs(value.translation.width) {
                        setExpanded(height < 0)
                    }
                }
            )
            .accessibilityElement()
            .accessibilityLabel(isExpanded ? "Hide more" : "More")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setExpanded(!isExpanded) }
    }

    /// One word, letter-spaced and lowercase, with the whole column beneath it as
    /// its target — words on one line are small, and a 44pt row is what keeps
    /// them pressable.
    private func word(_ tab: WordTab) -> some View {
        let isSelected = selection == tab

        return Button {
            select(tab)
        } label: {
            VStack(spacing: Theme.Spacing.tight) {
                Text(tab.word)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .kerning(1.6)
                    .foregroundStyle(isSelected ? Theme.Accent.brand : Theme.Ink.tertiary)

                // Weight and colour are otherwise the only things separating the
                // selected word — and colour alone is a signal some people
                // never see.
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

    /// The shelf closes behind a choice from the row that is always on show, and
    /// stays open behind one from the row it reveals — closing there would hide
    /// the only word carrying the selection, leaving three unmarked ones over a
    /// screen none of them names.
    private func select(_ tab: WordTab) {
        selection = tab

        if WordTab.primary.contains(tab) {
            setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
            isExpanded = expanded
        }
    }
}

/// Every place the chrome can put you, in the two rows it draws them as.
///
/// Lowercase because that is how they are drawn: the word is the label, and
/// there is no separate display form to keep in step with it.
private enum WordTab: String, Identifiable {
    case breathe
    case exercises
    case journey
    case settings

    /// The words always on show.
    static let primary: [WordTab] = [.breathe, .exercises, .journey]

    /// The words the pull reveals: everything reached for rarely enough that a
    /// permanent word would crowd the three that matter.
    static let secondary: [WordTab] = [.settings]

    var id: Self {
        self
    }

    var word: String {
        rawValue
    }
}
