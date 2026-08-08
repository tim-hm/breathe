import AuthenticationServices
import OndKit
import OndUI
import SwiftUI

/// What this install is, the two ways to change it, and the way out.
///
/// A section rather than a screen: signing in is not a gate and never becomes
/// one, so it sits in Settings beside the subscription rather than in front of
/// the app. Local-only is named on the row for the same reason — it is the state
/// most people will stay in, and a row that only offered a button would read as
/// something unfinished rather than as a choice already made.
///
/// The deletion below it is the promise the privacy policy makes, and what
/// Guideline 5.1.1(v) requires of an app that offers account creation. Its
/// confirmation has to say what goes *and* what does not, because the one thing
/// it cannot touch is the subscription — a person who deletes their account
/// believing the billing stops has been misled by omission.
///
/// The only place `AuthenticationServices` is touched. Everything the sheet
/// produces is reduced here to the one string the server acts on, which is what
/// leaves `AccountModel` drivable by a test on the host with no Apple sheet
/// anywhere in it.
struct AccountSection: View {
    let account: AccountModel

    /// Opens the system's own subscription sheet, which `SettingsView` presents.
    /// A binding rather than a sheet of this section's own, because the
    /// confirmation below has to point somewhere real when it says that only
    /// Apple can cancel a subscription — and there is no second place to point.
    @Binding var isManagingSubscription: Bool

    /// The button draws its own chrome and has to be legible against both
    /// palettes, which is a decision the system will not make for it.
    @Environment(\.colorScheme) private var colorScheme

    @State private var isConfirmingDeletion = false

    var body: some View {
        Section {
            LabeledContent("Account") {
                Text(account.state.title)
            }

            switch account.state {
            case .localOnly:
                SignInWithAppleButton(.signIn) { request in
                    // Nothing. The server reads the token's `sub` and files the
                    // history under it; a name and an email would be two more
                    // things held about somebody for no use at all.
                    request.requestedScopes = []
                } onCompletion: { result in
                    signIn(with: result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(account.isWorking)

            case .signedIn:
                Button("Sign out") {
                    Task { await account.signOut() }
                }
                .tint(Theme.Accent.brand)
                .disabled(account.isWorking)
            }
        } footer: {
            Text(footer)
        }
        .listRowBackground(Theme.Surface.raised)

        // Its own section, and offered in both states. Signing in was never what
        // created anything: an anonymous identity has a row, a journey and
        // possibly a subscription from its first request, so an erasure that
        // only appeared to signed-in people would be one most people could not
        // reach.
        Section {
            Button("Delete account", role: .destructive) {
                isConfirmingDeletion = true
            }
            .disabled(account.isWorking)
        }
        .listRowBackground(Theme.Surface.raised)
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await account.deleteAccount() }
            }
            // Beside the deletion rather than only named in the message,
            // because "only Apple can cancel it" is no use to somebody who
            // then has to go and find where.
            Button("Manage subscription") {
                isManagingSubscription = true
            }
        } message: {
            Text(
                "Your profile, your sessions and your breath-hold history are "
                    + "erased from this iPhone, from a paired Apple Watch, and from "
                    + "our servers. It cannot be undone.\n\n"
                    + "Deleting your account does not cancel your subscription — "
                    + "only Apple can do that, under Manage Subscription."
            )
        }
    }

    /// The failure, when there is one, and otherwise what each state means.
    ///
    /// One footer rather than a banner: the two sentences a person needs are
    /// about what happens to their practice, and they are needed exactly where
    /// the button is.
    private var footer: String {
        if let failure = account.failure {
            return failure
        }

        return switch account.state {
        case .localOnly:
            "Everything stays on this device. Signing in with Apple attaches "
                + "your practice to your Apple ID, so a new phone — or this one, "
                + "restored — picks up where you left off. You never have to."
        case .signedIn:
            "Signing out returns this device to local only, under a new "
                + "anonymous identity. What you have practised stays on this "
                + "device, and stays attached to your Apple ID for next time."
        }
    }

    /// Reduces whatever the system sheet produced to the one thing the server
    /// takes: the identity token, verbatim.
    ///
    /// The two downcasts are the framework's shape — `ASAuthorization.credential`
    /// is an existential and Apple ID is one of several kinds it can hold — and
    /// there is no non-casting way onto the token.
    private func signIn(with result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken,
                  let identityToken = String(data: token, encoding: .utf8)
            else {
                account.reportSignInFailure(
                    "Apple returned a credential this app could not read. Try again."
                )
                return
            }

            Task { await account.signIn(identityToken: identityToken) }

        case let .failure(error):
            // Cancelling is a decision rather than a failure, and a message
            // about it would be the app arguing with one just made.
            guard (error as? ASAuthorizationError)?.code != .canceled else { return }

            account.reportSignInFailure(error.localizedDescription)
        }
    }
}
