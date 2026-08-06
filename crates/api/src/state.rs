//! The one object injected into handlers.

use std::sync::Arc;

use sqlx::PgPool;

use crate::config::Config;

/// Shared as `Arc<AppState>` by both transports.
///
/// Flat on purpose. Grouping dependencies into sub-structs earns its keep once
/// there are enough of them to lose track of; with two, it would only add a
/// level of indirection between a handler and its pool.
pub struct AppState {
    pub pool: PgPool,
    pub config: Config,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config) -> Arc<Self> {
        Arc::new(Self { pool, config })
    }
}
