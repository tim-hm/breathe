import AuthenticationServices
import OndKit
import OndUI
import SwiftUI

/// What this install is, and the two ways to change it.
///
/// A section rather than a screen: signing in is not a gate and never becomes
/// one, so it sits in Settings beside the subscription rather than in front of
/// the app. Local-only is named on the row for the same reason — it is the state
/// most people will stay in, and a row that only offered a button would read as
/// something unfinished rather than as a choice already made.
///
/// The only place `AuthenticationServices` is touched. Everything the sheet
/// produces is reduced here to the one string the server acts on, which is what
/// leaves `AccountModel` drivable by a test on the host with no Apple sheet
/// anywhere in it.
struct AccountSection: View {
    let account: AccountModel

    /// The button draws its own chrome and has to be legible against both
    /// palettes, which is a decision the system will not make for it.
    @Environment(\.colorScheme) private var colorScheme

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
