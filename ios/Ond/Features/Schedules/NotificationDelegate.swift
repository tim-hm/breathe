import OndKit
import UserNotifications

/// Turns a tapped notification into a request on the router, and does nothing
/// else.
///
/// Thin on purpose, and untested for the same reason. `UNUserNotificationCenter`
/// has one delegate for the whole app, so whatever is decided here is decided
/// for every notification önd will ever send — and it is also the one object in
/// this feature no host test can construct. Both halves of the actual thinking
/// live in `OndKit`, where they can be: what the notification carries is
/// `NotificationPayload`'s, and where the tap goes is
/// `NotificationDestination`'s.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: NotificationRouter

    /// Builds the delegate, hands it to the notification centre, and returns it
    /// to be held.
    ///
    /// Returned rather than kept somewhere here because
    /// `UNUserNotificationCenter.delegate` is weak, and a delegate nobody
    /// retains is a tap that lands nowhere. Called from the composition root's
    /// `init` rather than from a `.task`: a notification tapped from terminated
    /// is delivered as the app launches, and a delegate installed after that has
    /// already missed it.
    @MainActor
    static func installed(routing router: NotificationRouter) -> NotificationDelegate {
        let delegate = NotificationDelegate(router: router)
        UNUserNotificationCenter.current().delegate = delegate
        return delegate
    }

    private init(router: NotificationRouter) {
        self.router = router
        super.init()
    }

    /// A tap on the notification itself, rather than a swipe away or one of the
    /// action buttons this app does not offer.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let payload = NotificationPayload(
                  userInfo: response.notification.request.content.userInfo
              )
        else { return }

        await router.request(payload)
    }
}
