import Foundation

/// The two documents a subscription app has to be able to show.
///
/// App-local rather than inside `Features/Plus/`, because they are not the
/// paywall's: App Review expects both reachable from Settings as well, and a
/// privacy policy is a promise the whole app makes rather than a term of the
/// purchase.
///
/// Both trap on an unparseable literal rather than substituting a fallback, the
/// same rule and for the same reason as `AppConfiguration.apiBaseURL`: a `Link`
/// that quietly opens something else is far harder to notice than a crash naming
/// the offending value, and these are exactly the two links a reviewer will tap.
enum LegalLinks {
    /// Apple's standard EULA, which is the terms this app ships under. Using
    /// Apple's own document rather than writing one is what makes this a link to
    /// a page that already exists and is already agreed.
    static let termsOfUse = url("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    /// The page this points at does not exist yet. `ondbreathe.app` is served
    /// by the same box as the API (`infra/box/Caddyfile`), so publishing it is
    /// a file in `web/`; App Review rejects a paywall whose privacy link 404s,
    /// which makes it a prerequisite for the first submission rather than for
    /// the screen that links to it.
    static let privacyPolicy = url("https://ondbreathe.app/privacy")

    private static func url(_ raw: String) -> URL {
        guard let url = URL(string: raw) else {
            preconditionFailure("not a valid URL: \(raw)")
        }

        return url
    }
}
