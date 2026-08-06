import BreatheUI
import SwiftUI

/// A row on the journey that leads somewhere: a title, a line of explanation,
/// an optional figure, and the chevron that says it is a way in.
///
/// The tab had three of these written out longhand — the pause test, the
/// leaderboards, and the name that opts you into them — differing only in their
/// words and whether a number sat on the right.
struct JourneyCard<Destination: View>: View {
    let title: String
    let caption: String
    /// Shown on the right in the attending accent, where there is one. The
    /// personal best is the only current use.
    var value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(title)
                        .font(.headline)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                }

                Spacer()

                if let value {
                    Text(value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Accent.attend)
                }

                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(Theme.Spacing.standard)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        // Plain, because the default link style tints the whole card in the
        // accent and the chevron is already saying it is tappable.
        .buttonStyle(.plain)
    }
}
