//! Migration runner for the `ond` database.
//!
//! Creates the database if it is absent, applies `migrations/`, then seeds the
//! technique catalogue. The work itself lives in `lib.rs` so the API's test
//! harness can bring a disposable database up the same way; this binary is the
//! command-line entry point onto it.

use std::str::FromStr;

use anyhow::{Context, Result};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};

/// Installs this binary's subscriber, in the format the API would have chosen.
///
/// Every deploy runs this binary into the same place the API logs, and
/// unstructured text beside JSON makes "did the migration apply" the one
/// deploy-time question a field query cannot answer.
///
/// A copy of `api::obs::init` rather than a call to it, because the dependency
/// runs the other way: `api` dev-depends on this crate so its test harness
/// brings a disposable database up exactly as `mise run migrate` does, and a
/// migration runner that linked the whole API to share eight lines would be the
/// wrong direction whether or not Cargo permitted it. A third crate for eight
/// lines is structure nobody reads.
///
/// What the copy can drift on is the *set* of environment names, not the
/// variable: `api` derives its format from `Environment`, and this compares one
/// literal. A third environment therefore has to be taught here too.
fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("migrate=info,warn"));

    let builder = tracing_subscriber::fmt().with_env_filter(filter);

    if std::env::var("OND_ENV").as_deref() == Ok("production") {
        builder.json().init();
    } else {
        builder.init();
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    init_logging();

    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;

    // Parsed into options rather than manipulated as a string. Deriving the
    // maintenance connection from these carries `sslmode` and every other
    // parameter across structurally, where string surgery would have to
    // reassemble them — and would quietly drop whatever it forgot.
    let options = PgConnectOptions::from_str(&database_url)
        .context("DATABASE_URL is not a valid Postgres connection string")?;
    let database_name = options
        .get_database()
        .context("DATABASE_URL names no database")?
        .to_owned();

    migrate::create_database_if_absent(&options, &database_name).await?;

    // No retry loop, here or in `connect_maintenance`: sqlx's pool already
    // retries a refused connection and SQLSTATE 57P03 ("the database system is
    // starting up") with backoff until `acquire_timeout` — which is exactly the
    // first-boot window a hand-written loop would be covering.
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .with_context(|| format!("failed to connect to `{database_name}`"))?;

    migrate::apply(&pool).await?;
    tracing::info!(database = %database_name, "database ready");

    Ok(())
}
