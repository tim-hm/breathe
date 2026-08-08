import Foundation
import Observation

/// Whether this person has agreed to the safety terms, and the record of it.
///
/// Replaces `SafetyNoteStore`, and inverts what it was for. That store kept a
/// per-exercise dismissal because the cautions were not one warning repeated —
/// box breathing's was about posture, the Wim Hof rounds' about passing out —
/// so agreeing to one could not be allowed to silence another. The cautions
/// were then consolidated into one screen that names every hazard at once, and
/// the moment there is a single set of words, a single agreement to them is the
/// honest thing to store. What used to be a preference about presentation is now
/// a record of something a person did.
///
/// Two things follow from that, and neither followed from the old store:
///
/// - it is written once and never edited, so there is no `undo`, no `clear`, and
///   no way for a screen to put a dismissal back;
/// - it keeps the words, not a flag. `needsConsent` going false has to be
///   answerable with *what* they agreed to and *when*, months later.
///
/// `UserDefaults` because the record belongs to the install: it is what this
/// device asked and this person answered, it has to survive a relaunch, and it
/// is a few hundred bytes written once. It is deliberately **not** on `Profile`
/// — a profile is answers about the person that sync to the server and restore
/// onto a new device, and consent restored onto a device that never showed the
/// screen is consent nobody gave.
@MainActor
@Observable
public final class SafetyConsentStore {
    private static let key = "safety.consent"

    /// What this person agreed to, or nil if they never have.
    public private(set) var agreed: AgreedSafetyConsent?

    /// The words to put on screen, and the words `record()` will store — one
    /// source for both, so what somebody read and what they agreed to cannot
    /// drift apart.
    public let terms: SafetyConsent

    private let defaults: UserDefaults

    /// - Parameter terms: the words to ask about. Injected so a test can raise
    ///   the version without editing the copy every screen shows.
    public init(terms: SafetyConsent = .current, defaults: UserDefaults = .standard) {
        self.terms = terms
        self.defaults = defaults
        agreed = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder.consent.decode(AgreedSafetyConsent.self, from: $0) }
    }

    /// Whether this person still has to be asked.
    ///
    /// True for a fresh install, and true for somebody who onboarded before this
    /// screen existed — they have no record, which is the same state as never
    /// having been asked, and being asked once is the point. It is not the same
    /// state as having agreed, and nothing here may treat it as such.
    ///
    /// Compared with `<` rather than `!=` so that running an older build against
    /// a newer record — a TestFlight downgrade — does not ask somebody to agree
    /// to terms they have already been past.
    public var needsConsent: Bool {
        guard let agreed else { return true }
        return agreed.version < terms.version
    }

    /// Records agreement to the terms as they currently read.
    ///
    /// Idempotent while `needsConsent` is false: the agreement that counts is
    /// the one that happened, and a second pass over the screen — someone
    /// stepping back and forward through onboarding — must not overwrite its
    /// timestamp with a later one.
    ///
    /// - Parameter now: when it happened. Injected only so a test can assert on
    ///   a time it chose.
    public func record(at now: Date = .now) {
        guard needsConsent else { return }

        let record = AgreedSafetyConsent(version: terms.version, agreedAt: now, text: terms.text)
        guard let encoded = try? JSONEncoder.consent.encode(record) else { return }

        defaults.set(encoded, forKey: Self.key)
        agreed = record
    }
}

private extension JSONEncoder {
    /// ISO-8601 dates, so the record on disk is legible to whoever has to read
    /// it — which is the whole reason for keeping one.
    static var consent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var consent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
