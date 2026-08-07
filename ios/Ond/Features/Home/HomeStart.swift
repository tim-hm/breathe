import Foundation
import OndKit

/// Starts a technique the way the home screen dialled it, or reports that a
/// subscription owns it.
///
/// Both home layouts route through this rather than each calling
/// `SessionModel.starting` themselves. That initialiser is failable for exactly
/// one reason — the subscription gate — and a second copy of the call is a
/// second place for the gate to be forgotten. The wheel suggests from the whole
/// catalogue, so home is a route to a session that never passes the techniques
/// list's lock, and this is the only thing standing in for it.
///
/// It resolves the technique the same way the detail screen's Begin does, so
/// the wheel and the dials cannot start different sessions.
@MainActor
struct HomeStart {
    let sessions: any SessionRecording
    let settings: SessionSettings
    let tier: SubscriptionTier

    /// The session to present, or nil where `technique` is locked and the
    /// paywall is what should open instead.
    func session(for technique: Technique) -> SessionModel? {
        let dialled = technique.dialled(with: settings.overrides(for: technique))
        return SessionModel.starting(
            dialled,
            for: tier,
            cues: SessionCues(mode: settings.cueMode, strength: settings.hapticStrength),
            recorder: sessions
        )
    }
}
