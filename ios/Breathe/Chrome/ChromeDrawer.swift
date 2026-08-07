import BreatheUI
import SwiftUI

/// The destinations the shelf reveals, one case per addition.
///
/// Everything that is not one of the three roots lives here — settings today,
/// a coach or whatever else tomorrow — so growing the drawer is a case, a word,
/// and a symbol, never a change to the shelf, the drag, or the routing.
enum DrawerDestination: String, CaseIterable, Identifiable {
    case settings

    var id: Self {
        self
    }

    /// Lowercase because that is how it is drawn, same as the tab words: the
    /// word is the label, with no separate display form to keep in step.
    var word: String {
        rawValue
    }

    /// The SF Symbol beside the word.
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        }
    }
}

/// The drawer under the word row, revealed when the shelf is pulled open.
///
/// It only reports the choice — opening the shelf, closing it, and what a
/// choice leads to are `AppChrome`'s, which is the one place that knows both
/// the gesture and the sheets.
///
/// A destination is a full-width row with a symbol and a chevron rather than
/// the bare lowercase word the tabs use. Three words side by side are plainly a
/// control; one word alone under them reads as a caption, and the rows have to
/// say they are pressable without a second surface to sit on — the shelf is
/// already `Surface.raised`, so a raised card here would have nothing to
/// contrast against. The hairline above each row does that work instead.
struct ChromeDrawer: View {
    let onChoose: (DrawerDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(DrawerDestination.allCases) { destination in
                // Above every row rather than between them, so the first one is
                // also parted from the words above it.
                Divider().overlay(Theme.Surface.line)

                row(destination)
            }
        }
    }

    private func row(_ destination: DrawerDestination) -> some View {
        Button {
            onChoose(destination)
        } label: {
            HStack(spacing: Theme.Spacing.standard) {
                Image(systemName: destination.symbol)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(destination.word)
                    .font(.footnote.weight(.regular))
                    .kerning(1.6)
                    .foregroundStyle(Theme.Ink.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
