import Foundation
import OndKit
import Testing

/// Dismissing a caution is the one preference in the app that could hide a
/// contraindication, so the isolation between exercises is the property under
/// test: putting away the note on a gentle exercise must never silence the one
/// on an exercise that can make somebody pass out.
@MainActor
@Suite("Putting a caution away, one exercise at a time")
struct SafetyNoteDismissalTests {
    private func defaults(_ name: String) -> UserDefaults {
        let suite = "safety-note-tests.\(name)"
        let store = UserDefaults(suiteName: suite)
        store?.removePersistentDomain(forName: suite)
        return store ?? .standard
    }

    private func technique(_ slug: String, note: String? = "Seated only.") -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: .calm,
            stages: [
                Stage(
                    phases: [Phase(kind: .inhale, duration: .seconds(4))],
                    cycles: 4
                ),
            ],
            recommendedRounds: 1,
            safetyNote: note
        )
    }

    @Test("Nothing is dismissed until somebody dismisses it")
    func startsShowing() {
        let store = SafetyNoteStore(defaults: defaults("fresh"))

        #expect(!store.hasDismissed(technique("box-breathing")))
    }

    @Test("Dismissing one exercise leaves every other one showing")
    func isolatesBySlug() {
        let store = SafetyNoteStore(defaults: defaults("isolation"))
        let box = technique("box-breathing")
        let rounds = technique("wim-hof-rounds", note: "Never in water.")

        store.dismiss(box)

        #expect(store.hasDismissed(box))
        #expect(
            !store.hasDismissed(rounds),
            "a caution about a different risk must not be silenced by an unrelated one"
        )
    }

    @Test("A dismissal survives the relaunch")
    func persists() {
        let suite = defaults("persistence")
        let box = technique("box-breathing")

        SafetyNoteStore(defaults: suite).dismiss(box)

        // A second store over the same defaults is what a relaunch looks like
        // from here: the first is gone, and only what reached disk is left.
        #expect(SafetyNoteStore(defaults: suite).hasDismissed(box))
    }

    @Test("Only what was dismissed comes back")
    func persistsOnlyTheDismissed() {
        let suite = defaults("persistence-isolation")

        SafetyNoteStore(defaults: suite).dismiss(technique("box-breathing"))

        let reopened = SafetyNoteStore(defaults: suite)
        #expect(reopened.hasDismissed(technique("box-breathing")))
        #expect(!reopened.hasDismissed(technique("wim-hof-rounds")))
    }

    @Test("Dismissing twice is dismissing once")
    func isIdempotent() {
        let suite = defaults("idempotent")
        let store = SafetyNoteStore(defaults: suite)
        let box = technique("box-breathing")

        store.dismiss(box)
        store.dismiss(box)

        #expect(suite.stringArray(forKey: "safety.dismissedNotes") == ["box-breathing"])
    }
}
