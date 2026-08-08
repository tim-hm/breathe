import Foundation
@testable import OndKit
import os
import Testing

/// The store the phone composes, over storage that never touches a Keychain.
private func mintingStore(holding id: UUID? = nil) -> KeychainUserIdentityStore {
    KeychainUserIdentityStore(storage: FakeStorage(holding: id))
}

/// `AccountService` with the two rules that decide what a sign-in does, and
/// nothing else.
///
/// The caller is read from the identity store on every call, exactly as
/// `IdentityInterceptor` reads it to stamp the header — which is what makes this
/// able to catch a client that signed out without changing its id, since the
/// server's refusal is a fact about *which* id called.
///
/// An identity token stands in for the Apple account it names, because `sub` is
/// the only claim the server acts on.
private final class FakeAccounts: AccountSyncing {
    /// Apple account → the identity holding it, which is `users.apple_user_id`
    /// read the way a sign-in reads it.
    private let bindings: OSAllocatedUnfairLock<[String: UUID]>
    private let identity: any UserIdentityStore

    init(identity: any UserIdentityStore, bindings: [String: UUID] = [:]) {
        self.identity = identity
        self.bindings = OSAllocatedUnfairLock(initialState: bindings)
    }

    /// Which identity each Apple account is filed under, after whatever has
    /// happened to them.
    var boundAccounts: [String: UUID] {
        bindings.withLock { $0 }
    }

    func signIn(identityToken: String) async throws -> UUID {
        guard let caller = identity.userId() else {
            throw AccountRepositoryError.transport("no identity to bind")
        }

        return try bindings.withLock { held in
            // Somebody's row holds this Apple account. It is that person's real
            // history, so the caller is merged into it and *deleted* — taking
            // whatever Apple account the caller was bound to with it, which is
            // the half of this that never surfaces as an error.
            if let holder = held[identityToken] {
                if holder != caller {
                    held = held.filter { $0.value != caller }
                }
                return holder
            }

            // `claim` refuses a caller already bound to another account, because
            // the column it would overwrite is the only record of the first one.
            if held.values.contains(caller) {
                throw AccountRepositoryError.boundElsewhere
            }

            held[identityToken] = caller
            return caller
        }
    }
}

/// Signing in, signing out, and the identity swap either performs.
///
/// Two of this issue's three seams are here, and both are silent in the field.
/// An install that keeps the id it signed out of is bound to that first Apple
/// account forever — the server refuses to rebind, by design, and there is no
/// way back that does not involve reinstalling. An install that ignores the id a
/// sign-in answered with writes onto a row the server recreates empty, which no
/// later sign-in will ever find.
@MainActor
@Suite("Account")
struct AccountModelTests {
    /// A `UserDefaults` nobody else shares, so one test cannot decide another's
    /// account state.
    private func defaults(_ name: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "account-tests.\(name).\(UUID().uuidString)"))
    }

    private func model(
        identity: any UserIdentityStore,
        accounts: any AccountSyncing,
        defaults: UserDefaults,
        onIdentityChange: @escaping @MainActor () async -> Void = {}
    ) -> AccountModel {
        AccountModel(
            identity: identity,
            accounts: accounts,
            defaults: defaults,
            onIdentityChange: onIdentityChange
        )
    }

    /// Restoring on a second device, which is what signing in is for: the Apple
    /// account already has an identity, this install's is merged into it, and
    /// the id that comes back is the one the person's practice is filed under.
    @Test("The identity the server answers with is adopted, and everything is told")
    func adoptsTheReturnedIdentity() async throws {
        let identity = mintingStore(holding: UUID())
        let history = UUID()
        let told = OSAllocatedUnfairLock(initialState: 0)
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity, bindings: ["apple-a": history]),
            defaults: defaults("adopts")
        ) {
            told.withLock { $0 += 1 }
        }

        await account.signIn(identityToken: "apple-a")

        #expect(identity.userId() == history)
        #expect(account.state == .signedIn)
        #expect(account.failure == nil)
        #expect(told.withLock { $0 } == 1, "the watch and the restore both hold the old id")
    }

    /// A first sign-in — nobody held this Apple account — is answered with the
    /// caller's own id. Nothing changed, so nothing should be woken to hear it.
    @Test("A first sign-in keeps the identity it arrived with")
    func keepsTheCallersIdentityOnAFirstSignIn() async throws {
        let held = UUID()
        let identity = mintingStore(holding: held)
        let told = OSAllocatedUnfairLock(initialState: 0)
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity),
            defaults: defaults("first-sign-in")
        ) {
            told.withLock { $0 += 1 }
        }

        await account.signIn(identityToken: "apple-a")

        #expect(identity.userId() == held)
        #expect(account.state == .signedIn)
        #expect(told.withLock { $0 } == 0)
    }

    /// One installation, two people, and the sign-out in between is the only
    /// thing standing between them. The second account already has an identity,
    /// so nothing here is refused — the caller's row is merged into theirs and
    /// deleted, and what it takes with it is the first account's binding.
    @Test("Sign in as one account, sign out, and sign in as another lands on their history")
    func signingOutKeepsTheFirstAccountsHistoryOutOfTheSecond() async throws {
        let identity = mintingStore(holding: UUID())
        let theirs = UUID()
        let accounts = FakeAccounts(identity: identity, bindings: ["apple-b": theirs])
        let account = try model(
            identity: identity,
            accounts: accounts,
            defaults: defaults("second-account")
        )

        await account.signIn(identityToken: "apple-a")
        let first = identity.userId()
        await account.signOut()
        await account.signIn(identityToken: "apple-b")

        #expect(account.failure == nil)
        #expect(account.state == .signedIn)
        #expect(identity.userId() == theirs)
        #expect(
            accounts.boundAccounts["apple-a"] == first,
            "the fresh identity is what is merged away, rather than the first account's"
        )
    }

    /// The same flow where the second account is new, which is where the server
    /// refuses rather than merges: `claim` will not rebind a row that already
    /// holds an Apple account, so an install that kept the id it signed out of
    /// can never sign in as anybody else again.
    @Test("Sign in, sign out, and sign in as a new account binds rather than being refused")
    func signingOutFreesTheInstallForANewAccount() async throws {
        let identity = mintingStore(holding: UUID())
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity),
            defaults: defaults("new-account")
        )

        await account.signIn(identityToken: "apple-a")
        await account.signOut()
        await account.signIn(identityToken: "apple-b")

        #expect(account.failure == nil)
        #expect(account.state == .signedIn)
    }

    @Test("Signing out mints an identity that is nobody's history")
    func signingOutMintsAFreshIdentity() async throws {
        let identity = mintingStore(holding: UUID())
        let told = OSAllocatedUnfairLock(initialState: 0)
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity),
            defaults: defaults("sign-out")
        ) {
            told.withLock { $0 += 1 }
        }

        await account.signIn(identityToken: "apple-a")
        let bound = identity.userId()
        await account.signOut()

        #expect(account.state == .localOnly)
        #expect(identity.userId() != nil)
        #expect(identity.userId() != bound)
        #expect(told.withLock { $0 } == 1, "the watch must stop syncing to the bound identity")
    }

    /// The one way an honest client reaches `FAILED_PRECONDITION`: the Keychain
    /// identity outlives a reinstall and `UserDefaults` does not, so the app
    /// offers a sign-in believing it is the first. The refusal is the server
    /// telling it otherwise, and recording that is what puts the sign-out — the
    /// only way back — in front of the person.
    @Test("A refusal reveals a binding this install had forgotten, and is recoverable")
    func recordsABindingItHadForgotten() async throws {
        let held = UUID()
        let identity = mintingStore(holding: held)
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity, bindings: ["apple-a": held]),
            defaults: defaults("forgotten")
        )

        await account.signIn(identityToken: "apple-b")

        #expect(account.state == .signedIn)
        #expect(account.failure != nil)

        await account.signOut()
        await account.signIn(identityToken: "apple-b")

        #expect(account.failure == nil)
        #expect(account.state == .signedIn)
    }

    /// Local-only is where everybody starts and most people stay, and nothing
    /// about it is a failure state.
    @Test("An install that has never signed in is local only")
    func startsLocalOnly() throws {
        let identity = mintingStore()
        let account = try model(
            identity: identity,
            accounts: FakeAccounts(identity: identity),
            defaults: defaults("fresh")
        )

        #expect(account.state == .localOnly)
        #expect(account.failure == nil)
    }
}
