import BreatheKit
import Foundation

/// Wraps the model so `fullScreenCover(item:)` has something `Identifiable` to
/// present.
///
/// The identity is the presentation's, not the session's — a new tap on Begin is
/// a new session, and this is what makes that unambiguous.
///
/// Beside `SessionView` rather than beside any one of the screens that present
/// it: three of them do, and they were each carrying a private copy of this.
struct StartedSession: Identifiable {
    let id = UUID()
    let model: SessionModel
}
