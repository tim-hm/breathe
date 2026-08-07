import SwiftUI

/// Three tabs, SF Symbol and label: breathe, read, look back.
///
/// The two the baseline loses are the two that were never destinations. The
/// basics are reference material the techniques list can hold at its foot, and
/// Settings is a place people go once — a gear on each of these three screens
/// is closer to how often it is wanted than a permanent fifth of the bar.
struct ThreeTabChrome: View {
    let roots: AppRoots

    var body: some View {
        TabView {
            Tab("Breathe", systemImage: "smallcircle.filled.circle") {
                roots.homeRoot
            }
            Tab("Techniques", systemImage: "square.grid.2x2") {
                roots.techniquesRoot
            }
            Tab("Journey", systemImage: "clock.arrow.circlepath") {
                roots.journeyRoot
            }
        }
    }
}
