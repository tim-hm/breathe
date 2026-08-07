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
public final class IdentityInterceptor: UnaryInterceptor {
    /// The header the server reads. Lowercase because gRPC metadata keys are.
    public static let headerName = "breathe-user-id"

    private let userId: @Sendable () -> UUID?

    public init(userId: @escaping @Sendable () -> UUID?) {
        self.userId = userId
    }

    @Sendable
    public func handleUnaryRawRequest(
        _ request: HTTPRequest<Data?>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Data?>, ConnectError>) -> Void
    ) {
        guard let id = userId() else {
            // No identity is not a failure to send: the catalogue is public, so
            // the app's first screen has to render before the Keychain has been
            // written. The server answers the scoped RPCs with UNAUTHENTICATED.
            proceed(.success(request))
            return
        }

        var headers = request.headers
        headers[Self.headerName] = [id.uuidString]

        proceed(.success(HTTPRequest(
            url: request.url,
            headers: headers,
            message: request.message,
            method: request.method,
            trailers: request.trailers,
            idempotencyLevel: request.idempotencyLevel
        )))
    }
}
