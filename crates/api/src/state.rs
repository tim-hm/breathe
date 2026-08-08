//! The one object injected into handlers.

use std::sync::Arc;

use sqlx::PgPool;

use crate::config::Config;
use crate::features::account::verifier::IdentityTokenVerifier;
use crate::features::assistant::model::ModelClient;
use crate::features::entitlement::verifier::TransactionVerifier;

/// Shared as `Arc<AppState>` by both transports.
///
/// Flat on purpose. Grouping dependencies into sub-structs earns its keep once
/// there are enough of them to lose track of; with four, it would only add a
/// level of indirection between a handler and its pool.
pub struct AppState {
    pub pool: PgPool,
    pub config: Config,

    /// The language model, chosen once at startup.
    ///
    /// Injected exactly as the pool is, and for the same reason: it is the
    /// other thing in this process that talks to something outside it, and a
    /// handler holding a concrete client instead would be a handler no test
    /// could point somewhere harmless. `crate::assistant` re-exports the trait
    /// for the composition root; this field carries the chosen implementation
    /// down to the one service that calls it.
    pub assistant: Arc<dyn ModelClient>,

    /// The App Store signature checker.
    ///
    /// Injected for the same reason as the model, and with the opposite
    /// emphasis: the model is here so a test can point it somewhere harmless,
    /// and this is here so a test can supply a transaction Apple never signed.
    /// Nothing configures it — the trust anchor is compiled in — so the field
    /// exists purely as the seam.
    pub entitlement: Arc<dyn TransactionVerifier>,

    /// The Sign in with Apple credential checker.
    ///
    /// Here for the same reason as the App Store verifier, and with one thing
    /// the others do not have behind it: this one holds Apple's published keys,
    /// so the seam is also what keeps a test suite off the network rather than
    /// merely off Apple's signatures.
    pub account: Arc<dyn IdentityTokenVerifier>,
}

impl AppState {
    pub fn new(
        pool: PgPool,
        config: Config,
        assistant: Arc<dyn ModelClient>,
        entitlement: Arc<dyn TransactionVerifier>,
        account: Arc<dyn IdentityTokenVerifier>,
    ) -> Arc<Self> {
        Arc::new(Self {
            pool,
            config,
            assistant,
            entitlement,
            account,
        })
    }
}
