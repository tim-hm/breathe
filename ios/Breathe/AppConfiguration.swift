import Foundation

/// Where this build points its API.
///
/// Read from the environment rather than hard-coded so that running against a
/// physical device — which cannot reach the Mac's `localhost` — is a change to
/// the scheme, not a change to the source.
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
        let raw = ProcessInfo.processInfo.environment["BREATHE_API_BASE_URL"] ?? defaultBaseURL

        guard let url = URL(string: raw) else {
            preconditionFailure("BREATHE_API_BASE_URL is not a valid URL: \(raw)")
        }

        return url
    }()
}
