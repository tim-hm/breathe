//! Telemetry initialisation.
//!
//! Logging convention (docs/observability.md): log at boundaries, stay silent in
//! between. Handlers log outcomes; services and repositories communicate through
//! typed errors and say nothing.

use tracing_subscriber::EnvFilter;

/// Installs the global subscriber.
///
/// The formatter is chosen once, at boot, from the environment: JSON is
/// unreadable in a terminal and mandatory in a log aggregator, and only one of
/// those is ever reading.
pub fn init(json: bool) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("api=info,tower_http=info,warn"));

    let builder = tracing_subscriber::fmt().with_env_filter(filter);

    if json {
        builder.json().init();
    } else {
        builder.init();
    }
}
