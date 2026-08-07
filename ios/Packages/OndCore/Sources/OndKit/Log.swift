import os

/// The one subsystem the phone, the watch and this shared package all log under.
///
/// Deriving it from `Bundle.main.bundleIdentifier` names the *host process*, so
/// a file in this package filed under one subsystem when the phone loaded it and
/// another when the watch did — and `log stream --subsystem xyz.holmie.ond`
/// then silently omitted the watch, the target whose failures are hardest to
/// reproduce.
public enum Log {
    public static let subsystem = "xyz.holmie.ond"
}

public extension Logger {
    /// A logger on the app's own subsystem, which is the only one worth writing
    /// to — this initialiser exists so that getting it right takes fewer
    /// keystrokes than getting it wrong.
    ///
    /// - Parameter category: the channel, named for what it carries rather than
    ///   for the file it sits in, so both ends of the phone↔watch handoff file
    ///   under `watch-link`. `docs/observability.md` holds the set.
    init(category: String) {
        self.init(subsystem: Log.subsystem, category: category)
    }
}
