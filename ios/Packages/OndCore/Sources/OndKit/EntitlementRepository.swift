import Foundation
import OndAPI

public enum EntitlementRepositoryError: LocalizedError, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    /// Includes the server refusing the transaction, which is `INVALID_ARGUMENT`
    /// and is not retryable; the distinction does not matter to the one caller,
    /// because a submission that will never succeed and one that has not
    /// succeeded yet are both "not synced" and both cost the person nothing.
    case transport(String)

    /// Carries the associated message. Without this conformance
    /// `localizedDescription` bridges to a bare `NSError`, and every log line
    /// and failure banner reading it says "The operation couldn't be completed".
    public var errorDescription: String? {
        switch self {
        case let .transport(message): "the request failed: \(message)"
        }
    }
}

/// Carries a purchase to the server, and nothing back.
///
/// Deliberately one-way. `StoreKit` is the authority on what this app shows —
/// it answers offline and needs no round trip — so a read here would be a second
/// opinion about a question already settled. What the server holds decides only
/// what the server spends, which is the assistant's allowance, and this app
/// never needs to know that number.
public protocol EntitlementSyncing: Sendable {
    /// Submits a `Transaction.jwsRepresentation` for verification.
    ///
    /// Idempotent on the server, which is what makes the retry policy trivial:
    /// resubmitting the same transaction writes the same entitlement rather than
    /// a second one.
    func submit(_ signedTransaction: String) async throws
}

/// The only type that touches the generated entitlement types, mirroring
/// `ProfileRepository`.
public struct EntitlementRepository: EntitlementSyncing {
    private let client: Ond_V1_EntitlementServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = OndClients.entitlementService(baseURL: baseURL, userId: identity.userId)
    }

    public func submit(_ signedTransaction: String) async throws {
        var request = Ond_V1_SubmitAppStoreTransactionRequest()
        request.signedTransaction = signedTransaction

        let response = await client.submitAppStoreTransaction(request: request)

        guard response.message != nil else {
            throw EntitlementRepositoryError.transport(
                response.error?.localizedDescription ?? "the server sent no message"
            )
        }
    }
}
