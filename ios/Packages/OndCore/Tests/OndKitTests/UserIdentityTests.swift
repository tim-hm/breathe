import Connect
import Foundation
import OndAPI
@testable import OndKit
import Testing

/// The identity seam, driven through the protocol rather than the Keychain.
///
/// What a store does with an id — minting one, and swapping it on a sign-in —
/// is `MintedIdentityTests` and `ProvisionedIdentityTests`. This is the half
/// above the protocol, and it is worth pinning on its own because a header that
/// goes missing is invisible until a scoped RPC fails in the app.
@Suite("Anonymous identity")
struct UserIdentityTests {
    /// Answers with whatever it was handed, which is the only behaviour the
    /// interceptor depends on. Swapping is not part of that: what a store does
    /// with one is tested where the swap lives.
    private struct FakeIdentityStore: UserIdentityStore {
        let stored: UUID?

        func userId() -> UUID? {
            stored
        }

        func adopt(_: UUID) -> Bool {
            false
        }
    }

    /// One fixture for both hooks: they differ only in the body type, which is
    /// `Data?` for a unary call and `Void` for a stream opening.
    private func request<Input>(_ path: String, message: Input) throws -> HTTPRequest<Input> {
        let url = try #require(URL(string: "http://localhost:18100/ond.v1.\(path)"))
        return HTTPRequest(
            url: url,
            headers: ["content-type": ["application/grpc-web+proto"]],
            message: message,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )
    }

    private func headers(from interceptor: IdentityInterceptor) async throws -> Headers {
        let request = try request("ProfileService/GetProfile", message: Data?.none)
        return await withCheckedContinuation { continuation in
            interceptor.handleUnaryRawRequest(request) { result in
                continuation.resume(returning: (try? result.get())?.headers ?? [:])
            }
        }
    }

    private func streamHeaders(from interceptor: IdentityInterceptor) async throws -> Headers {
        let request = try request("AssistantService/Chat", message: ())
        return await withCheckedContinuation { continuation in
            interceptor.handleStreamStart(request) { result in
                continuation.resume(returning: (try? result.get())?.headers ?? [:])
            }
        }
    }

    @Test("Every request carries the stored id, alongside the headers already set")
    func attachesTheIdentityHeader() async throws {
        let id = UUID()
        let store = FakeIdentityStore(stored: id)
        let interceptor = IdentityInterceptor(userId: store.userId)

        let headers = try await headers(from: interceptor)

        #expect(headers[IdentityInterceptor.headerName] == [id.uuidString])
        #expect(
            headers["content-type"] == ["application/grpc-web+proto"],
            "the interceptor replaces the header map, so it has to carry the rest across"
        )
    }

    /// No identity is not a reason to fail the call: the catalogue is public and
    /// the app's first screen renders before the Keychain has been written. The
    /// server answers the scoped RPCs with UNAUTHENTICATED, which is a state the
    /// repository already reports.
    @Test("A request goes out unattributed rather than failing when there is no id")
    func sendsAnonymouslyWithoutAnIdentity() async throws {
        let interceptor = IdentityInterceptor(userId: FakeIdentityStore(stored: nil).userId)

        let headers = try await headers(from: interceptor)

        #expect(headers[IdentityInterceptor.headerName] == nil)
        #expect(headers["content-type"] == ["application/grpc-web+proto"])
    }

    /// The regression this suite exists for. `IdentityInterceptor` documents why
    /// the streaming hook is a separate seam; this pins that it is wired.
    @Test("A stream carries the id too, not just a unary call")
    func attachesTheIdentityHeaderToStreams() async throws {
        let id = UUID()
        let interceptor = IdentityInterceptor(userId: FakeIdentityStore(stored: id).userId)

        let headers = try await streamHeaders(from: interceptor)

        #expect(headers[IdentityInterceptor.headerName] == [id.uuidString])
        #expect(headers["content-type"] == ["application/grpc-web+proto"])
    }

    @Test("A stream opens unattributed rather than failing when there is no id")
    func opensStreamsAnonymouslyWithoutAnIdentity() async throws {
        let interceptor = IdentityInterceptor(userId: FakeIdentityStore(stored: nil).userId)

        let headers = try await streamHeaders(from: interceptor)

        #expect(headers[IdentityInterceptor.headerName] == nil)
        #expect(headers["content-type"] == ["application/grpc-web+proto"])
    }

    /// The header name is one string agreed with `crates/api/src/identity.rs`.
    /// Lowercase because gRPC metadata keys are, and a mixed-case one is invalid
    /// over HTTP/2 rather than merely unconventional.
    @Test("The header name matches what the server reads")
    func usesTheAgreedHeaderName() {
        #expect(IdentityInterceptor.headerName == "ond-user-id")
    }
}
