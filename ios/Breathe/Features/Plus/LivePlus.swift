import BreatheKit
import Foundation

/// The Plus store, built once for the whole app.
///
/// The same shape as `LiveAssistant`, and for the same reason: the surfaces that
/// gate on a subscription hang off screens reached from more than one place, so
/// a new required initialiser parameter on each would have meant editing every
/// call site of all of them. Each takes the store as a *defaulted* parameter
/// instead, so moving the construction into `BreatheApp` later is one line there
/// and the deletion of this file.
///
/// Unlike the assistant's, this is genuinely one instance rather than merely one
/// construction: `PlusStore` holds state, and two of them would each cache their
/// own answer and each submit the same purchase.
///
/// `KeychainUserIdentityStore` reads the same Keychain item `BreatheApp` does,
/// so the purchase is attributed to the same person every other call is.
@MainActor
enum LivePlus {
    static let store = PlusStore(
        front: StoreKitPlusStoreFront(),
        entitlements: EntitlementRepository(
            baseURL: AppConfiguration.apiBaseURL,
            identity: KeychainUserIdentityStore()
        )
    )
}
