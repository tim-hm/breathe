import Foundation
import Observation
import os

/// What this install is, as far as the person using it is concerned.
///
/// Two states and no third, because there is no half-signed-in: the identity
/// either carries an Apple credential or it does not, and everything about the
/// app works either way.
public enum AccountState: Sendable, Equatable {
    /// Everything on this device and nothing filed anywhere under a name. The
    /// state a person is in until they choose otherwise, and a first-class
    /// choice rather than a degraded one — nobody should have to sign in to
    /// breathe.
    case localOnly

    /// Bound to an Apple account, so this practice is reachable from a new
    /// phone, a restore, or a second device.
    case signedIn

    /// What Settings shows beside the account row.
    public var title: String {
        switch self {
        case .localOnly: "Local only"
        case .signedIn: "Signed in with Apple"
        }
    }
}

/// Signing in, signing out, deleting the account, and the identity swap all
/// three of them perform.
///
/// The swap is the reason this is a model rather than three lines in a view.
/// Sign in and the server may answer with an identity *older* than the caller's,
/// having merged this install's history into it; sign out and this install must
/// stop using the identity it just bound, or the next person to sign in here
/// either cannot, or inherits a stranger's practice — `signOut` has the full
/// account of that. Delete, and the id names nothing at all, while the server
/// would recreate it the moment anything asked. All three are the same rule: the
/// client is the authority on which id is live, so every path that changes it
/// changes it completely, and every one of them ends with everything holding a
/// copy being told.
@MainActor
@Observable
public final class AccountModel {
    private static let logger = Logger(category: "account")

    /// Whether this install has bound an Apple account.
    ///
    /// Kept in `UserDefaults` rather than the Keychain, which means a reinstall
    /// reads back `.localOnly` while the surviving Keychain identity may still
    /// be bound. That install's next sign-in is answered with
    /// `boundElsewhere` if it names a different Apple account, and `signIn`
    /// below records what the server just revealed — so the state repairs
    /// itself, and the sign-out that is the way back becomes reachable.
    public private(set) var state: AccountState {
        didSet { defaults.set(state == .signedIn, forKey: Self.signedInKey) }
    }

    /// What went wrong, for the one screen that asked. Cleared by the next
    /// attempt, since a stale reason beside a fresh button is worse than none.
    public private(set) var failure: String?

    /// Whether a sign-in is on the wire. The RPC reaches Apple's key endpoint
    /// through the server on a cold key cache, so this is long enough to need
    /// saying.
    public private(set) var isWorking = false

    private static let signedInKey = "account.signedIn"

    private let identity: any UserIdentityStore
    private let accounts: any AccountSyncing
    private let stores: [any PersonalStore]
    private let defaults: UserDefaults
    private let onIdentityChange: @MainActor () async -> Void

    /// - Parameter stores: everything on this device that holds something about
    ///   the person, for `deleteAccount` to empty. Listed by the composition
    ///   root rather than discovered, because there is no way to discover one
    ///   and a store left off the list is a deletion that quietly is not one.
    /// - Parameter onIdentityChange: run after the identity has actually
    ///   changed, to tell everything holding a copy of it — the watch, which
    ///   carries its own, and the journey, whose restore has already run under
    ///   the old one. A closure because both of those are composed above this
    ///   package, and one because they are one event.
    public init(
        identity: any UserIdentityStore,
        accounts: any AccountSyncing,
        stores: [any PersonalStore],
        defaults: UserDefaults = .standard,
        onIdentityChange: @escaping @MainActor () async -> Void
    ) {
        self.identity = identity
        self.accounts = accounts
        self.stores = stores
        self.defaults = defaults
        self.onIdentityChange = onIdentityChange
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read.
        state = defaults.bool(forKey: Self.signedInKey) ? .signedIn : .localOnly
    }

    /// Binds the Apple credential and adopts whatever identity comes back.
    ///
    /// The adopt happens before this returns and before anything else is
    /// awaited, so no request can be stamped with the merged-away id after the
    /// server has deleted it.
    public func signIn(identityToken: String) async {
        failure = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let adopted = try await accounts.signIn(identityToken: identityToken)
            state = .signedIn

            if identity.adopt(adopted) {
                Self.logger.notice("adopted the identity this Apple account already had")
                await onIdentityChange()
            }
        } catch AccountRepositoryError.boundElsewhere {
            // The server has just told us something this install had forgotten:
            // it is bound, to somebody else's Apple account. Recording that is
            // what puts the sign-out in front of the person, which is the only
            // route from here to signing in as the account they offered.
            state = .signedIn
            failure = "This device is already signed in to a different Apple ID. "
                + "Sign out first, then sign in again."
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Returns this install to local-only under a **fresh** anonymous identity.
    ///
    /// Minting is the point rather than a detail. An install that kept the id it
    /// just signed out of stays bound to that first Apple account, and the next
    /// sign-in as somebody else goes one of two ways, both bad. If that account
    /// is new, `bind_apple_account` refuses it — rebinding would drop the first
    /// account's only route back to its history — and nothing on either side can
    /// undo that short of reinstalling. If that account already has an identity,
    /// there is no refusal at all: the caller's row is merged into theirs and
    /// deleted, so the first person's practice is handed to the second and their
    /// binding goes with it.
    ///
    /// The id is minted here rather than asked of the store because `UUID()` is
    /// not knowledge about where an identity is kept, and because the store that
    /// must never invent one is the watch's.
    ///
    /// What stays behind is the practice already on this device: it is theirs,
    /// it is what the journey draws from with no signal at all, and the sync
    /// ledger has it acknowledged — so it is not re-sent, and signing in as
    /// somebody else does not donate this history to them.
    public func signOut() async {
        failure = nil
        state = .localOnly

        if identity.adopt(UUID()) {
            await onIdentityChange()
        }
    }

    /// Erases the account on the server, then everything this device holds about
    /// the person, and starts them again under an identity nobody has ever seen.
    ///
    /// Offered whether or not this install has signed in, because signing in was
    /// never what created anything: an anonymous identity has a row, sessions, a
    /// controlled-pause history and possibly an entitlement from its first RPC.
    /// A "delete account" that only appeared once you had one would leave the
    /// majority of people with no way to erase what is held about them.
    ///
    /// The order below is the whole of the correctness, and each step is only
    /// safe after the one above it:
    ///
    /// 1. **The server first.** Nothing local is touched until the row is gone,
    ///    so a request that failed leaves a device that can simply ask again.
    ///    Erasing first would strand somebody offline with an empty app and a
    ///    server that still holds everything.
    /// 2. **A fresh identity next, before anything is awaited.** The old id
    ///    names nothing now, and `identity::resolve` upserts a row for any
    ///    well-formed id it is shown — so a single request that slipped out
    ///    under it would recreate the erased person as an empty stranger. This
    ///    is the rule signing out follows, for a sharper version of the same
    ///    reason.
    /// 3. **Then the local stores**, each of which answers for its own files,
    ///    keys and in-memory copies.
    /// 4. **Then everything holding a copy of the identity**, which is where the
    ///    watch is told — and told *after* the erasure rather than before, so
    ///    the context it is handed carries the fresh id and no personal best,
    ///    rather than the departing person's.
    ///
    /// What survives is the App Store subscription, which is not this app's to
    /// cancel. `SubscriptionStore.erase` re-derives it from `StoreKit` on the
    /// way past, and the confirmation that leads here says so plainly.
    public func deleteAccount() async {
        failure = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await accounts.delete()
        } catch {
            failure = error.localizedDescription
            return
        }

        identity.adopt(UUID())
        state = .localOnly

        for store in stores {
            await store.erase()
        }

        Self.logger.notice("erased the account and everything this device held")
        await onIdentityChange()
    }

    /// Records a failure that happened before there was a token to send — the
    /// system's own sheet failing, or a credential this app could not read.
    ///
    /// Separate from `signIn` because nothing reached the server, so there is no
    /// status to interpret and nothing about the identity has changed.
    public func reportSignInFailure(_ message: String) {
        failure = message
    }
}
