//! Re-exports of the types generated from `proto/` by `build.rs`.
//!
//! Everything reaches the generated code through this module rather than
//! `include_proto!`-ing it in several places, so the generated namespace has one
//! definition site.

pub mod ond {
    // prost and tonic emit this module; its style is theirs, not ours. A finding
    // here can only ever be silenced, never fixed, so the module is exempted as a
    // whole rather than growing a per-lint list every time a message is added.
    #[allow(clippy::all, clippy::pedantic)]
    pub mod v1 {
        tonic::include_proto!("ond.v1");

        /// Serves the schema over gRPC reflection, which is what lets `grpcurl`
        /// call a development server without a local copy of the .proto files.
        /// `grpc::build_services` registers it on local environments only.
        pub const FILE_DESCRIPTOR_SET: &[u8] =
            tonic::include_file_descriptor_set!("ond_v1_descriptor");
    }
}
