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
}

/// The drawer behind the word row: a short sheet of secondary destinations.
///
/// It only reports the choice — presentation, dismissal, and what a choice
/// opens are `AppChrome`'s, because a sheet cannot present the next sheet
/// itself; the chrome dismisses this one first.
struct ChromeDrawer: View {
    let onChoose: (DrawerDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(DrawerDestination.allCases) { destination in
                row(destination)
            }
        }
        .padding(.top, Theme.Spacing.loose)
        .padding(.horizontal, Theme.Spacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.ground)
    }

    private func row(_ destination: DrawerDestination) -> some View {
        Button {
            onChoose(destination)
        } label: {
            Text(destination.word)
                .font(.body.weight(.medium))
                .kerning(1.6)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
