import Foundation

/// The session store each screen records through, with one addition: every
/// session it keeps is also credited to Health as Mindful Minutes.
///
/// A wrapper rather than a change to `FileSessionStore`, because only *new*
/// practice earns minutes: the sync queue and the restore path work on the bare
/// store underneath, so history arriving from the server — possibly written to
/// Health already, by the device that breathed it — never writes again. And
/// only `record` writes here: the store's own discard rule has already thrown
/// out the mistaps, and minutes actually breathed count whether or not the
/// plan ran out.
public struct MindfulMinutesRecorder: SessionRecording {
    private let store: any SessionRecording
    private let health: any HealthStore

    public init(wrapping store: any SessionRecording, health: any HealthStore) {
        self.store = store
        self.health = health
    }

    public func record(_ session: SessionRecord) async {
        await store.record(session)

        // The one place write access is asked for: the moment there are
        // minutes to credit. Asked every time because a repeat request is
        // cheap — the store answers it without a prompt — and if the answer
        // was no, the write below fails as silently as it was refused.
        await health.requestWriteAuthorization()
        await health.writeMindfulSession(
            from: session.startedAt,
            to: session.startedAt.addingTimeInterval(session.duration.seconds)
        )
    }

    public func recordedSessions() async -> [SessionRecord] {
        await store.recordedSessions()
    }

    public func remove(_ id: SessionRecord.ID) async {
        await store.remove(id)
    }

    public func merge(_ sessions: [SessionRecord]) async -> Bool {
        await store.merge(sessions)
    }
}
