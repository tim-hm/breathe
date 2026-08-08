import Foundation
import Observation

/// The road from a tapped notification to the screen it opens.
///
/// State rather than a call, and that is the whole of the design. A notification
/// tapped from terminated is handed to the delegate while the scene is still
/// being composed, so a delegate that called a view would be calling one that
/// does not exist yet — and the tap that launched the app would be the single
/// tap the app ignored. This holds the request instead and the chrome takes it
/// once there is a chrome, which makes a cold launch and a warm one the same
/// path at different speeds.
///
/// It knows nothing about screens or about schedules, which is what lets a push
/// from the server arrive exactly the way a local reminder does.
@MainActor
@Observable
public final class NotificationRouter {
    /// What a tap asked for and nothing has opened yet.
    public private(set) var pending: NotificationPayload?

    public init() {}

    /// Records a tap. The most recent one wins: two reminders tapped before
    /// either opened is one person changing their mind, not two exercises.
    public func request(_ payload: NotificationPayload) {
        pending = payload
    }

    /// Takes the request, leaving nothing behind.
    ///
    /// Consuming rather than reading, so a route is followed once — a session
    /// screen dismissed must not be reopened by the request that opened it, and
    /// a request that resolves to no exercise must not be retried on every pass.
    public func take() -> NotificationPayload? {
        defer { pending = nil }
        return pending
    }
}
