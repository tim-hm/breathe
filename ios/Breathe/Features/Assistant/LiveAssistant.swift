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
        identity: KeychainUserIdentityStore()
    )
}
