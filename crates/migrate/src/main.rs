//! Migration runner for the `breathe` database.
//!
//! Creates the database if it is absent, applies `migrations/`, then seeds the
//! technique catalogue. The work itself lives in `lib.rs` so the API's test
//! harness can bring a disposable database up the same way; this binary is the
//! command-line entry point onto it.

use std::str::FromStr;

use anyhow::{Context, Result};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("migrate=info")),
        )
        .init();

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
