import BreatheUI
import SwiftUI

/// The destinations the word row lifts up, one case per addition.
///
/// Everything that is not one of the three roots lives here — settings today,
/// a coach or whatever else tomorrow — so growing the drawer is a case and a
/// word, never a change to the sheet, the swipe, or the routing.
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

    /// The symbol beside the word. A bare word centred on a sheet reads as a
    /// caption, not a control — which is how the drawer came to look empty to
    /// people who had just swiped it open.
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        }
    }
}

/// The drawer behind the word row: a short sheet of secondary destinations.
///
/// It only reports the choice — presentation, dismissal, and what a choice
/// opens are `AppChrome`'s, because a sheet cannot present the next sheet
/// itself; the chrome dismisses this one first.
///
/// Each destination is drawn as a raised row with a symbol and a chevron rather
/// than in the bare lowercase word the tab row uses. The word alone is right on
/// the tab row, where three of them side by side are plainly a control; alone on
/// a sheet it read as a heading over an empty panel, and people swiped the
/// drawer open and reported finding nothing in it.
struct ChromeDrawer: View {
    let onChoose: (DrawerDestination) -> Void

    /// The sheet's detent, measured from the rows it will hold rather than
    /// fixed: a guessed height either crops the last destination or leaves a
    /// panel of empty ground under the first, and the drawer grows by a case.
    static var detentHeight: CGFloat {
        let rows = CGFloat(DrawerDestination.allCases.count)
        return headroom
            + rows * rowHeight
            + (rows - 1) * Theme.Spacing.close
            + Theme.Spacing.loose
    }

    private static let rowHeight: CGFloat = 56
    /// Room above the first row for the drag indicator, which draws inside the
    /// sheet rather than above it and would otherwise land on the row.
    private static let headroom: CGFloat = 32

    var body: some View {
        VStack(spacing: Theme.Spacing.close) {
            ForEach(DrawerDestination.allCases) { destination in
                row(destination)
            }
        }
        .padding(.top, Self.headroom)
        .padding(.horizontal, Theme.Spacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.ground)
    }

    private func row(_ destination: DrawerDestination) -> some View {
        Button {
            onChoose(destination)
        } label: {
            HStack(spacing: Theme.Spacing.standard) {
                Image(systemName: destination.symbol)
                    .font(.body)
                    .foregroundStyle(Theme.Accent.brand)

                Text(destination.word)
                    .font(.body.weight(.medium))
                    .kerning(1.6)
                    .foregroundStyle(Theme.Ink.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            .background(Theme.Surface.raised, in: .rect(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
