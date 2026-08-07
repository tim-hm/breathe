import Foundation

/// Who said one turn of the conversation.
public enum ChatRole: Sendable, Equatable {
    /// The person using the app.
    case person

    /// The coach — the assistant's own earlier reply, kept so it can be read
    /// back to the server as attributed speech.
    case coach
}

/// One turn of the conversation with the coach.
///
/// The transcript is an array of these, oldest first, and it lives only in
/// memory for the length of one app run: the server keeps no conversation
/// state at all, so what the device holds is the only copy, and this app
/// deliberately does not persist it yet (a flagged follow-up, not V1).
public struct ChatTurn: Sendable, Equatable, Identifiable {
    /// Stable across the reply growing chunk by chunk, so SwiftUI animates one
    /// paragraph filling in rather than replacing a row per chunk.
    public let id: UUID
    public let role: ChatRole
    public let text: String

    public init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    /// The longest message the server accepts, in characters — the client
    /// half of the server's `MAX_CHAT_MESSAGE_CHARS`, enforced by clamping
    /// the composer as it is typed (the intent note's pattern), so a long
    /// paste can never turn into an `INVALID_ARGUMENT` that reads as the
    /// network failing.
    public static let maxMessageLength = 1000

    /// How much history one request carries — the client half of the
    /// server's `MAX_CHAT_TURNS`. The server silently drops anything older,
    /// so sending more would upload bytes it provably throws away.
    public static let maxHistoryDepth = 20
}
