import Connect
import Foundation

/// Builds the generated service clients against a configured backend.
///
/// The transport is fixed here rather than at each call site: every client must
/// agree on protocol, codec, and the identity header, and the one place that is
/// guaranteed is the place they are all constructed.
public enum BreatheClients {
    public static func techniqueService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Breathe_V1_TechniqueServiceClient {
        Breathe_V1_TechniqueServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    public static func profileService(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> Breathe_V1_ProfileServiceClient {
        Breathe_V1_ProfileServiceClient(client: protocolClient(baseURL: baseURL, userId: userId))
    }

    private static func protocolClient(
        baseURL: URL,
        userId: @escaping @Sendable () -> UUID?
    ) -> ProtocolClient {
        ProtocolClient(
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
