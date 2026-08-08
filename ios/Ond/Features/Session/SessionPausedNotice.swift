import UserNotifications

/// The one thing a stopped session can still say to somebody who has pocketed a
/// silent phone: that it stopped.
///
/// A session whose cues cannot follow the person out of the app pauses when they
/// leave — `SessionCues.playsInBackground` carries the why — and a pause nobody
/// is told about is the actual fault, because they breathe to nothing and find
/// out on their return. A local notification is the only channel left at that
/// point: the app has no runtime, and a locked screen withholds its haptics.
enum SessionPausedNotice {
    /// One identifier for the one notice there can be, so `withdraw()` takes
    /// back exactly this and never a reminder a schedule placed.
    private static let identifier = "session-paused"

    /// How long a departure has to last before it is worth saying anything.
    ///
    /// iOS sends `.background` for a two-second glance at another app as readily
    /// as for a phone going into a pocket, and buzzing somebody over the first
    /// would be worse than the silence this exists to fix. A return inside the
    /// window withdraws the request before it ever fires.
    private static let quietPeriod: TimeInterval = 15

    /// Asks for the notice, if the person is still away when the window closes.
    ///
    /// Authorization is deliberately not requested here, only used if it is
    /// already held: the prompt would surface on their return, at the end of a
    /// session, to ask about a thing that has already happened. Unauthorized,
    /// `add` is a no-op and the pause stays as quiet as it is today.
    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "Your session is paused"
        content.body =
            "With sound off, önd can't reach a locked screen. Open it to carry on where you left off."
        // Sound, despite this being somebody who chose a silent practice,
        // because it is the only part of the notice that reaches a pocket: the
        // system plays a notification's alert itself, so it still lands as a
        // vibration on a phone switched to silent, where the app's own haptics
        // never would.
        content.sound = .default
        // No `NotificationPayload`, deliberately. The tap should return to the
        // session already on screen — which resuming on `.active` does — rather
        // than route to the exercise and open a second one over it.

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: quietPeriod,
                    repeats: false
                )
            )
        )
    }

    /// Takes the notice back, whether or not one was ever posted.
    ///
    /// Both lists, because a return can beat the quiet period or lose to it, and
    /// a delivered "your session is paused" outliving the pause is the same lie
    /// in the other direction.
    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
