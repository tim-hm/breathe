#if DEBUG
    import BreatheUI
    import SwiftUI

    /// The two runtime dials for the chrome prototype, at the top of Settings.
    ///
    /// The whole file sits inside `#if DEBUG`, so a release build cannot
    /// reference it even by mistake. It leads Settings because while the two
    /// dials are still being decided it is the reason a debug build is being
    /// opened at all.
    struct DesignLabSection: View {
        @Environment(DesignVariants.self) private var variants

        var body: some View {
            @Bindable var variants = variants

            Section {
                Picker("Navigation", selection: $variants.navigation) {
                    ForEach(NavigationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                Picker("Home", selection: $variants.home) {
                    ForEach(HomeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Design lab")
            } footer: {
                Text("Debug builds only. Both take effect straight away and "
                    + "survive a relaunch.")
            }
            .listRowBackground(Theme.Surface.raised)
        }
    }
#endif
