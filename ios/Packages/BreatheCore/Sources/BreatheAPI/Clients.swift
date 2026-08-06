import Connect
import Foundation

/// Builds the generated service clients against a configured backend.
///
/// The transport is fixed here rather than at each call site: every client must
/// agree on protocol and codec, and the one place that is guaranteed is the
/// place they are all constructed.
public enum BreatheClients {
    public static func techniqueService(baseURL: URL) -> Breathe_V1_TechniqueServiceClient {
        Breathe_V1_TechniqueServiceClient(client: protocolClient(baseURL: baseURL))
    }

    private static func protocolClient(baseURL: URL) -> ProtocolClient {
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
                codec: ProtoCodec()
            )
        )
    }
}
