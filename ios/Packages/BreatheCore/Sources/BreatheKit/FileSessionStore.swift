import Foundation

/// Session history as one JSON file.
///
/// An actor because the write is read-modify-write and a session ending while
/// the sync queue is draining the file must not interleave.
public actor FileSessionStore: SessionRecording {
    private let file: JSONFileStore<SessionRecord>
    private let tombstones: JSONFileStore<UUID>

    /// - Parameter directory: where `sessions.json` lives. Defaults to
    ///   Application Support — user data the system backs up and never purges,
    ///   unlike Caches. Tests pass a temporary directory.
    public init(directory: URL = .applicationSupportDirectory) {
        file = JSONFileStore(
            directory: directory,
            fileName: "sessions.json",
            category: "session-store"
        )
        tombstones = JSONFileStore(
            directory: directory,
            fileName: "deleted-sessions.json",
            category: "session-store"
        )
    }

    public func record(_ session: SessionRecord) async {
        var sessions = file.load()
        sessions.append(session)
        file.save(sessions)
    }

    /// Adds sessions the server holds and this device does not, skipping any
    /// already here — and any deleted here, which the server may still hold.
    ///
    /// The restore path, and the one place history flows backwards: the identity
    /// lives in the Keychain and survives a reinstall, so somebody who deletes
    /// the app and comes back has a server full of sessions and an empty file.
    /// Matching on id is what makes this safe to call after every sync.
    public func merge(_ sessions: [SessionRecord]) async -> Bool {
        var existing = file.load()
        let unwanted = Set(existing.map(\.id)).union(tombstones.load())
        let missing = sessions.filter { !unwanted.contains($0.id) }
        guard !missing.isEmpty else { return false }

        existing.append(contentsOf: missing)
        existing.sort { $0.startedAt < $1.startedAt }
        file.save(existing)
        return true
    }

    /// Deletes a session and tombstones its id, because deletion is local-only:
    /// the sync never takes anything back off the server, so without the
    /// tombstone the next restore would quietly hand the session straight back.
    /// The server's copy therefore outlives this — a reinstall (which loses the
    /// tombstone file) resurrects deleted sessions, the same class of caveat as
    /// the restore's 50-session cap. A `DeleteSessions` RPC closes that when
    /// deletion earns a server round-trip.
    public func remove(_ id: SessionRecord.ID) async {
        let sessions = file.load()
        let remaining = sessions.filter { $0.id != id }
        guard remaining.count != sessions.count else { return }

        file.save(remaining)
        tombstones.save(tombstones.load() + [id])
    }

    public func recordedSessions() async -> [SessionRecord] {
        file.load()
    }
}
