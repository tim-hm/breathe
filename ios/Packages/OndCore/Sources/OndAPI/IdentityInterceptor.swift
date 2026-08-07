import Connect
import Foundation

/// Puts this install's anonymous id on every outbound RPC.
///
/// One interceptor rather than a `headers:` argument at each call site: the
/// header is not optional per-call, and a repository that forgot it would fail
/// only against the services that require one — which is the half of the API
/// nobody tests by hand.
///
/// Takes a closure rather than a store type because this target sits below
/// `OndKit` in the module graph and cannot name the protocol that owns the
/// Keychain. The closure is `@Sendable` and re-read per request, so an identity
/// minted after the client was built is still picked up.
///
/// Both halves of the seam, and that is the whole point. Connect dispatches
/// unary calls and streams through separate protocols, so a `UnaryInterceptor`
/// alone is silently skipped on every server-streaming RPC — the header simply
/// never goes out and the server answers `UNAUTHENTICATED`. That is not a
/// visible wiring error either: the unary calls keep working, so the app looks
/// healthy while `ExplainTechnique` and `Chat` fail on every attempt. Adding a
/// streaming RPC means nothing here; dropping `StreamInterceptor` breaks all of
/// them at once.
public final class IdentityInterceptor: UnaryInterceptor, StreamInterceptor {
    /// The header the server reads. Lowercase because gRPC metadata keys are.
    public static let headerName = "ond-user-id"

    private let userId: @Sendable () -> UUID?

    public init(userId: @escaping @Sendable () -> UUID?) {
        self.userId = userId
    }

    @Sendable
    public func handleUnaryRawRequest(
        _ request: HTTPRequest<Data?>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Data?>, ConnectError>) -> Void
    ) {
        proceed(.success(stamped(request)))
    }

    /// A stream's headers are settled once, when it opens — there is no
    /// per-message hook that reaches them, so this is the only place the id can
    /// join a streaming call.
    @Sendable
    public func handleStreamStart(
        _ request: HTTPRequest<Void>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Void>, ConnectError>) -> Void
    ) {
        proceed(.success(stamped(request)))
    }

    /// The request with the id on it, or unchanged when there is none.
    ///
    /// Generic over the body because the two hooks above carry different ones —
    /// `Data?` for a unary call, `Void` for a stream opening — and the header is
    /// the only thing either of them touches.
    private func stamped<Input: Sendable>(_ request: HTTPRequest<Input>) -> HTTPRequest<Input> {
        guard let id = userId() else {
            // No identity is not a failure to send: the catalogue is public, so
            // the app's first screen has to render before the Keychain has been
            // written. The server answers the scoped RPCs with UNAUTHENTICATED.
            return request
        }

        var headers = request.headers
        headers[Self.headerName] = [id.uuidString]

        return HTTPRequest(
            url: request.url,
            headers: headers,
            message: request.message,
            method: request.method,
            trailers: request.trailers,
            idempotencyLevel: request.idempotencyLevel
        )
    }
}
