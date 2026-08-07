import Foundation
import Observation

/// How the app's roots are presented.
///
/// Four treatments of one question: five tabs is the iOS maximum, so a bar with
/// five in it reads as slots filled rather than choices made. The three that
/// follow all drop to Breathe, Techniques and Journey — the basics move inside
/// the techniques list and Settings goes behind a gear — and differ only in how
/// loudly the bar announces itself.
enum NavigationStyle: String, CaseIterable, Identifiable {
    /// Five tabs, SF Symbol and label. What the app ships today, and the
    /// baseline the other three are judged against.
    case fiveTabs
    /// Three tabs, SF Symbol and label.
    case threeTabs
    /// The same three as lowercase letter-spaced words on a bar, no icons.
    case threeWords
    /// The same three words with no bar at all: no ground, no hairline, resting
    /// on the bottom edge with the content running full-bleed behind them.
    case wordRow

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .fiveTabs: "Five tabs"
        case .threeTabs: "Three tabs"
        case .threeWords: "Three words"
        case .wordRow: "Bar-less words"
        }
    }

    /// Whether Settings and the basics keep tabs of their own.
    ///
    /// Only the baseline has room for five, so every other style has to put
    /// them somewhere: the basics at the foot of the techniques list, Settings
    /// behind a gear. Asked once, here, rather than by each chrome — two
    /// screens change shape on the answer and they must agree.
    var hasFiveTabs: Bool {
        self == .fiveTabs
    }
}

/// How the way in is laid out.
enum HomeStyle: String, CaseIterable, Identifiable {
    /// The wheel, the technique it resolves to, and a Begin button.
    case current
    /// The wheel, a caption naming the technique, and the orb — which is the
    /// Begin button rather than sitting above one.
    case minimal

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .current: "Current"
        case .minimal: "Minimal"
        }
    }
}

#if DEBUG
    /// Which treatment of each dial is on screen, chosen at runtime from the
    /// design lab at the top of Settings.
    ///
    /// Debug-only in the strongest sense the language offers: nothing outside a
    /// debug build can name this type, so a release build has no way to leave the
    /// baseline. `UserDefaults` rather than a value passed in, so a choice made on
    /// a phone survives the relaunch it takes to judge it.
    @MainActor
    @Observable
    final class DesignVariants {
        private static let navigationKey = "design.navigation"
        private static let homeKey = "design.home"

        var navigation: NavigationStyle {
            didSet { defaults.set(navigation.rawValue, forKey: Self.navigationKey) }
        }

        var home: HomeStyle {
            didSet { defaults.set(home.rawValue, forKey: Self.homeKey) }
        }

        private let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            // Assigning in an initialiser does not run `didSet`, which is what
            // keeps this from writing back the value it just read.
            navigation = defaults.string(forKey: Self.navigationKey)
                .flatMap(NavigationStyle.init(rawValue:)) ?? .fiveTabs
            home = defaults.string(forKey: Self.homeKey)
                .flatMap(HomeStyle.init(rawValue:)) ?? .current
        }
    }
#endif
