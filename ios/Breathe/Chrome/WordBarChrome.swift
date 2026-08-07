import BreatheUI
import SwiftUI

/// The same three roots as `ThreeTabChrome`, under words instead of icons.
///
/// Hand-built rather than a `TabView`: a `Tab` always reserves the image well
/// above its label, so a label-only tab item comes out as a word floating under
/// the space an icon used to occupy. A `ZStack` of the three roots gives back
/// the one thing the `TabView` was providing — every root stays in the hierarchy
/// across a switch, so coming back to a screen lands where it was left.
///
/// The row takes its space from the roots by standing beside them in a `VStack`
/// rather than by insetting their safe area. `safeAreaInset` is the obvious
/// tool and it does not work here: a `NavigationStack` ignores an inset applied
/// from outside it, so every root lays out as though the row were not there and
/// the words land on top of whatever is at the foot of the screen. What that
/// costs is content scrolling *under* the words, which only the bare
/// presentation ever wanted; the palette's ground runs to the physical edge
/// either way, so both still read as one continuous page.
struct WordBarChrome: View {
    /// Whether the words sit on a bar or on the content itself.
    enum Presentation {
        /// A ground and a hairline under the words: a tab bar with the icons
        /// taken out.
        case bar
        /// No ground and no hairline — three words resting on the bottom edge
        /// with the content running full-bleed behind them, the selected one
        /// underlined.
        case bare
    }

    let roots: AppRoots
    let presentation: Presentation

    @State private var selection: WordTab = .breathe

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                root(.breathe) { roots.homeRoot }
                root(.techniques) { roots.techniquesRoot }
                root(.journey) { roots.journeyRoot }
            }
            row
        }
        // The row stops at the safe area, above the home indicator. The ground
        // carries on past it to the physical edge, so neither presentation
        // leaves a strip of system background under the words.
        .background(Theme.Surface.ground.ignoresSafeArea())
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
        .background(alignment: .top) { hairline }
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// The only mark separating a bar from no bar at all: the ground under the
    /// words is the same in both, so this line is what makes one of them read as
    /// a bar.
    @ViewBuilder
    private var hairline: some View {
        switch presentation {
        case .bar:
            Rectangle()
                .fill(Theme.Surface.line)
                .frame(height: 0.5)
        case .bare:
            EmptyView()
        }
    }

    /// One word, letter-spaced and lowercase, with the whole column beneath it
    /// as its target — three words on one line are small, and a 44pt row is
    /// what keeps them pressable.
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
                // signal some people never see. The bar presentation has its
                // own ground doing that job, so it keeps the space and hides
                // the mark rather than reflowing on selection.
                Capsule()
                    .fill(isSelected ? Theme.Accent.brand : .clear)
                    .frame(width: 16, height: 2)
                    .opacity(presentation == .bare ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The three roots a word row offers.
///
/// Lowercase because that is how they are drawn: the word is the label, and
/// there is no separate display form to keep in step with it.
private enum WordTab: String, CaseIterable, Identifiable {
    case breathe
    case techniques
    case journey

    var id: Self {
        self
    }

    var word: String {
        rawValue
    }
}
