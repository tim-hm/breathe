import Foundation

/// Where this build of the watch app points its API.
///
/// The watch talks to the backend directly rather than proxying through the
/// phone, so it needs the URL as much as the phone does and reads it from the
/// same place: the value `mise run ios:gen` bakes into the gitignored Info.plist
/// — the generating Mac's Bonjour address.
///
/// Narrower than the phone's `AppConfiguration` by one source. There is no
/// environment-variable override here because the wrist is where an override is
/// least reachable: a watch app is launched from the face or the app grid far
/// more often than from Xcode, and a setting that only applies under the
/// debugger would be a setting that is usually not in effect.
enum WatchConfiguration {
    /// 18100 matches the port `crates/api` binds. The watch simulator shares the
    /// Mac's loopback, so this reaches a backend started with `mise run dev`.
    private static let defaultBaseURL = "http://localhost:18100"

    /// A `let`, not a computed `var`: it is read once at composition and there
    /// is nothing about it that can change while the app runs.
    static let apiBaseURL: URL = {
        let raw = bakedBaseURL ?? defaultBaseURL

        guard let url = URL(string: raw) else {
            preconditionFailure("BreatheAPIBaseURL is not a valid URL: \(raw)")
        }

        return url
    }()

    /// Debug-only: a release build must never chase a development Mac, however
    /// the plist it shipped with was produced.
    private static var bakedBaseURL: String? {
        #if DEBUG
            Bundle.main.object(forInfoDictionaryKey: "BreatheAPIBaseURL") as? String
        #else
            nil
        #endif
    }
}
