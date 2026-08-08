import Foundation

/// Where this build points its API.
///
/// Three sources, most deliberate first: the `OND_API_BASE_URL` environment
/// variable, then the URL `ios:gen` bakes into the Info.plist, then the default
/// for the build configuration. The environment variable only exists while
/// Xcode's debugger launches the app — an app opened from the home screen never
/// sees it — which is why a physical device cannot rely on it and reads the
/// baked URL instead. Both of the first two are development affordances: the
/// baked URL compiles away in Release, and no app launched from a home screen
/// or from TestFlight has an environment to override it with — so a shipped
/// build resolves to the configuration default and nothing else.
enum AppConfiguration {
    // Where a build points when nothing more deliberate says otherwise.
    //
    // Release has one answer and it is the deployed one: a TestFlight build
    // installs on a phone that has never heard of the developer's Mac, and
    // pointing it at loopback would produce an app that launches and then
    // fails every request. Debug keeps localhost, where 18100 matches the port
    // `crates/api` binds and the simulator shares the Mac's loopback, so it
    // reaches a backend started with `mise run dev`.
    //
    // The host is the same literal as `LegalLinks.privacyPolicy` and as the
    // site block in `infra/box/Caddyfile` — one deployment serves the API and
    // the marketing page, split by path.
    #if DEBUG
        private static let defaultBaseURL = "http://localhost:18100"
    #else
        private static let defaultBaseURL = "https://ondbreathe.app"
    #endif

    /// Traps on an unparseable override rather than silently falling back to
    /// localhost. Someone who sets `OND_API_BASE_URL` wants that host; quietly
    /// substituting a different one produces an app that works and is talking to
    /// the wrong backend, which is far harder to notice than a crash naming the
    /// offending value.
    ///
    /// A `let`, not a computed `var`: reading it snapshots the whole process
    /// environment into a fresh dictionary, and a `var` invites call sites to do
    /// that repeatedly.
    static let apiBaseURL: URL = {
        let raw = ProcessInfo.processInfo.environment["OND_API_BASE_URL"]
            ?? bakedBaseURL
            ?? defaultBaseURL

        guard let url = URL(string: raw) else {
            preconditionFailure("OND_API_BASE_URL is not a valid URL: \(raw)")
        }

        return url
    }()

    /// The generating Mac's Bonjour address, written into the gitignored
    /// Info.plist by `mise run ios:gen` — see that task for the mechanism. This
    /// is what lets a device build launched from the home screen, with no
    /// debugger and therefore no environment, still find the dev backend.
    ///
    /// Debug-only: a release build must never chase a development Mac, however
    /// the plist it shipped with was produced.
    private static var bakedBaseURL: String? {
        #if DEBUG
            Bundle.main.object(forInfoDictionaryKey: "OndAPIBaseURL") as? String
        #else
            nil
        #endif
    }
}
