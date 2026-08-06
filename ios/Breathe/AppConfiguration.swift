import Foundation

/// Where this build points its API.
///
/// Three sources, most deliberate first: the `BREATHE_API_BASE_URL` environment
/// variable, then the URL `ios:gen` bakes into the Info.plist, then localhost.
/// The environment variable only exists while Xcode's debugger launches the app
/// — an app opened from the home screen never sees it — which is why a physical
/// device cannot rely on it and reads the baked URL instead.
enum AppConfiguration {
    /// 18100 matches the port `crates/api` binds. The simulator shares the Mac's
    /// loopback, so `localhost` reaches a backend started with `mise run dev`.
    private static let defaultBaseURL = "http://localhost:18100"

    /// Traps on an unparseable override rather than silently falling back to
    /// localhost. Someone who sets `BREATHE_API_BASE_URL` wants that host; quietly
    /// substituting a different one produces an app that works and is talking to
    /// the wrong backend, which is far harder to notice than a crash naming the
    /// offending value.
    ///
    /// A `let`, not a computed `var`: reading it snapshots the whole process
    /// environment into a fresh dictionary, and a `var` invites call sites to do
    /// that repeatedly.
    static let apiBaseURL: URL = {
        let raw = ProcessInfo.processInfo.environment["BREATHE_API_BASE_URL"]
            ?? bakedBaseURL
            ?? defaultBaseURL

        guard let url = URL(string: raw) else {
            preconditionFailure("BREATHE_API_BASE_URL is not a valid URL: \(raw)")
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
            Bundle.main.object(forInfoDictionaryKey: "BreatheAPIBaseURL") as? String
        #else
            nil
        #endif
    }
}
