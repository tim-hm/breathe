import SwiftUI

/// Five tabs, SF Symbol and label — the chrome the app ships today.
///
/// Kept beside the alternatives rather than left in `BreatheApp` so the four are
/// read side by side, and so choosing one of the others is a deletion rather
/// than a rewrite.
struct FiveTabChrome: View {
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
            Tab("The basics", systemImage: "book") {
                roots.basicsRoot
            }
            Tab("Settings", systemImage: "gearshape") {
                roots.settingsRoot()
            }
        }
    }
}
