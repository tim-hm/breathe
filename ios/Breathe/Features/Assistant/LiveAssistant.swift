import BreatheKit
import Foundation

/// The assistant's repository, built once for the whole app.
///
/// A file-scoped composition rather than a value threaded down from
/// `BreatheApp`, because the two surfaces that show guidance hang off views
/// reached from more than one place — a new required initialiser parameter on
/// either would have meant editing every call site of both. Each surface takes
/// the reading as a *defaulted* parameter instead, so moving the construction
/// into the composition root later is one line there and the deletion of this
/// file: nothing else changes, and neither view has to learn where its
/// dependency comes from.
///
/// `KeychainUserIdentityStore` reads the same Keychain item `BreatheApp` does,
/// so this is the same person — the store is a reader over one shared item, not
/// a second source of identity.
enum LiveAssistant {
    static let reading: any AssistantReading = AssistantRepository(
        baseURL: AppConfiguration.apiBaseURL,
        identity: KeychainUserIdentityStore(),
        // Asked per request, so withdrawing the opt-in in Settings takes
        // effect on the very next question with no restart.
        healthContext: { await LiveHealth.model.context() }
    )
}

/// The heart-trends opt-in and its summary, shared between the Settings
/// toggle that flips it and the repository above that asks it. One instance
/// on the same file-scoped-composition terms as `LiveAssistant`: the two
/// surfaces are nowhere near each other in the view tree, and the opt-in has
/// to be the same switch wherever it is read.
enum LiveHealth {
    @MainActor static let model = HealthContextModel(store: HealthKitHealthStore())
}

/// The coach's speaking voice, built once on the same terms as the two above.
///
/// One instance because a default parameter is evaluated on every view
/// construction — a fresh `SystemCoachVoice` there would allocate a
/// synthesiser per body pass of whatever screen links to the chat — and
/// because two synthesisers contending for one audio session would duck and
/// un-duck each other.
enum LiveCoachVoice {
    @MainActor static let voice: any CoachVoice = SystemCoachVoice()
}
