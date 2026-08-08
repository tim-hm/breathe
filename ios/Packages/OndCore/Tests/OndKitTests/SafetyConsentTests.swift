import Foundation
@testable import OndKit
import Testing

/// The consent screen is the only place the app names the hazards that used to
/// sit on four exercises, and the record it leaves is the only evidence anyone
/// agreed. Both halves are pinned here: the words, so a copy edit cannot quietly
/// drop a warning, and the record, so a screen that satisfies nobody cannot pass
/// for one that does.
@MainActor
@Suite("Agreeing to the safety terms")
struct SafetyConsentTests {
    /// A `UserDefaults` nobody else shares, so a test cannot read another's
    /// record or the developer's own.
    private func defaults(_ name: String) -> UserDefaults {
        let suite = "safety-consent-tests.\(name)"
        let store = UserDefaults(suiteName: suite)
        store?.removePersistentDomain(forName: suite)
        return store ?? .standard
    }

    /// The catalogue-side twin of `the_contraindicated_techniques_carry_their_warnings`
    /// in `crates/migrate/src/seed.rs`. Between them, every hazard the
    /// per-technique cautions used to name is asserted by a test: the two that
    /// still interrupt a session are pinned in the seed, and all four are pinned
    /// here, where the one screen that carries them lives.
    ///
    /// Phrases rather than sentences, for the same reason: the wording may be
    /// improved, the hazards may not disappear.
    @Test("The terms name every hazard the per-technique cautions used to")
    func namesEveryHazard() {
        let text = SafetyConsent.current.text.lowercased()

        for phrase in ["faint", "water", "driv", "lightheaded", "drowsy"] {
            #expect(text.contains(phrase), "the safety terms no longer mention `\(phrase)`")
        }
    }

    @Test("Nobody has agreed until somebody agrees")
    func startsUnasked() {
        let store = SafetyConsentStore(defaults: defaults("fresh"))

        #expect(store.needsConsent)
        #expect(store.agreed == nil)
    }

    /// What was agreed to and when — the two things that make a consent record
    /// worth keeping. The text is stored rather than reconstructed, so the words
    /// somebody actually saw survive the next copy edit.
    @Test("Agreeing records the words and the moment")
    func recordsWhatWasAgreedAndWhen() {
        let store = SafetyConsentStore(defaults: defaults("record"))
        let when = Date(timeIntervalSince1970: 1_770_000_000)

        store.record(at: when)

        #expect(!store.needsConsent)
        #expect(store.agreed?.agreedAt == when)
        #expect(store.agreed?.version == SafetyConsent.current.version)
        #expect(store.agreed?.text == SafetyConsent.current.text)
    }

    @Test("A recorded agreement survives the relaunch")
    func persists() {
        let suite = defaults("persistence")
        let when = Date(timeIntervalSince1970: 1_770_000_000)

        SafetyConsentStore(defaults: suite).record(at: when)

        // A second store over the same defaults is what a relaunch looks like
        // from here: the first is gone, and only what reached disk is left.
        let reopened = SafetyConsentStore(defaults: suite)
        #expect(!reopened.needsConsent)
        #expect(reopened.agreed?.agreedAt == when)
        #expect(reopened.agreed?.text == SafetyConsent.current.text)
    }

    /// Stepping back and forward over the screen must not restamp the record:
    /// the agreement that counts is the one that happened.
    @Test("Agreeing twice keeps the first agreement")
    func isIdempotent() {
        let store = SafetyConsentStore(defaults: defaults("idempotent"))
        let first = Date(timeIntervalSince1970: 1_770_000_000)

        store.record(at: first)
        store.record(at: first.addingTimeInterval(3600))

        #expect(store.agreed?.agreedAt == first)
    }

    /// The point of versioning the terms: a hazard added to the copy has to
    /// reach people who agreed to the copy without it.
    @Test("Newer terms ask again, and the old record says what was agreed before")
    func newerTermsAskAgain() {
        let suite = defaults("version")
        let when = Date(timeIntervalSince1970: 1_770_000_000)

        SafetyConsentStore(terms: terms(version: 1), defaults: suite).record(at: when)

        let asking = SafetyConsentStore(terms: terms(version: 2), defaults: suite)
        #expect(asking.needsConsent)
        #expect(asking.agreed?.version == 1)
        #expect(asking.agreed?.agreedAt == when, "the earlier agreement is still on the record")
    }

    /// A build older than the record — a TestFlight downgrade — must not ask
    /// somebody to agree to terms they have already been past.
    @Test("Older terms do not ask again")
    func olderTermsDoNotAskAgain() {
        let suite = defaults("downgrade")

        SafetyConsentStore(terms: terms(version: 2), defaults: suite).record()

        #expect(!SafetyConsentStore(terms: terms(version: 1), defaults: suite).needsConsent)
    }

    private func terms(version: Int) -> SafetyConsent {
        SafetyConsent(
            version: version,
            title: "Before you start",
            intro: "Terms at version \(version).",
            points: ["Sit or lie down."],
            agreement: "I understand"
        )
    }
}
