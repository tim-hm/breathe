//! The one object injected into handlers.

use std::sync::Arc;

use sqlx::PgPool;

use crate::config::Config;
use crate::features::assistant::model::ModelClient;

/// Shared as `Arc<AppState>` by both transports.
///
/// Flat on purpose. Grouping dependencies into sub-structs earns its keep once
/// there are enough of them to lose track of; with three, it would only add a
/// level of indirection between a handler and its pool.
pub struct AppState {
    pub pool: PgPool,
    pub config: Config,

    /// The language model, chosen once at startup.
    ///
    /// Injected exactly as the pool is, and for the same reason: it is the
    /// other thing in this process that talks to something outside it, and a
    /// handler holding a concrete client instead would be a handler no test
    /// could point somewhere harmless. `features::assistant::model` owns the
    /// trait; this field carries the chosen implementation from the composition
    /// root down to the one service that calls it.
    pub assistant: Arc<dyn ModelClient>,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config, assistant: Arc<dyn ModelClient>) -> Arc<Self> {
        Arc::new(Self {
            pool,
            config,
            assistant,
        })
    }
}
