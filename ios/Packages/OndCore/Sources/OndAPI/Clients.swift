import Connect
import Foundation

/// Builds the generated service clients against a configured backend.
///
/// The transport is fixed here rather than at each call site: every client must
/// agree on protocol, codec, and the identity header, and the one place that is
/// guaranteed is the place they are all constructed.
public enum OndClients {
    /// One `URLSession` for the whole app, not one per service.
    ///
    /// `ProtocolClient` builds its own `URLSessionHTTPClient` — and therefore
    /// its own session — by default, so a second service would otherwise mean a
    /// second connection pool to the same host: another TCP and TLS handshake,
    /// and no multiplexing between the catalogue call and the profile sync that
    /// launch fires alongside it.
    private static let httpClient = URLSessionHTTPClient()

    public static func techniqueService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_TechniqueServiceClient {
        Ond_V1_TechniqueServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func profileService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_ProfileServiceClient {
        Ond_V1_ProfileServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func journeyService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_JourneyServiceClient {
        Ond_V1_JourneyServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func assistantService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_AssistantServiceClient {
        Ond_V1_AssistantServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func accountService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_AccountServiceClient {
        Ond_V1_AccountServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func entitlementService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Ond_V1_EntitlementServiceClient {
        Ond_V1_EntitlementServiceClient(client: protocolClient(
            baseURL: baseURL,
            userId: userId
        ))
    }

    private static func protocolClient(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> ProtocolClient {
        ProtocolClient(
            httpClient: httpClient,
            config: ProtocolClientConfig(
                host: baseURL.absoluteString,
                // gRPC-Web, not Connect: the server is tonic behind
                // `tonic_web::GrpcWebLayer`, which serves gRPC-Web. Switching
                // this to `.connect` produces requests the server answers with
                // an unimplemented status. docs/transport.md has the full
                // reasoning.
                networkProtocol: .grpcWeb,
                // Binary protobuf. `JSONCodec` is the library default and would
                // silently disagree with the server's content type.
                codec: ProtoCodec(),
                // Applied to every client, including the catalogue's: the server
                // creates a person's row on the first RPC of any kind, so the
                // identity has to travel on the public calls too.
                interceptors: [InterceptorFactory { _ in IdentityInterceptor(userId: userId) }]
            )
        )
    }
}
