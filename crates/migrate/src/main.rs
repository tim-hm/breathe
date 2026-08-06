//! Migration runner for the `breathe` database.
//!
//! Creates the database if it is absent, applies `migrations/`, then seeds the
//! technique catalogue. Safe to run repeatedly — every step is idempotent, which
//! is what lets `mise run migrate` be the one command a new clone needs.

mod seed;

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
    // maintenance connection with `.database()` below carries `sslmode` and every
    // other parameter across structurally, where string surgery would have to
    // reassemble them — and would quietly drop whatever it forgot.
    let options = PgConnectOptions::from_str(&database_url)
        .context("DATABASE_URL is not a valid Postgres connection string")?;
    let database_name = options
        .get_database()
        .context("DATABASE_URL names no database")?
        .to_owned();

    ensure_database_exists(&options, &database_name).await?;

    // No retry loop, here or below: sqlx's pool already retries a refused
    // connection and SQLSTATE 57P03 ("the database system is starting up") with
    // backoff until `acquire_timeout` — which is exactly the first-boot window a
    // hand-written loop would be covering.
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .with_context(|| format!("failed to connect to `{database_name}`"))?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("failed to apply migrations")?;
    tracing::info!(database = %database_name, "migrations applied");

    seed::run(&pool).await?;

    Ok(())
}

/// Creates the database if it does not already exist.
///
/// `CREATE DATABASE` cannot run from inside the database being created, so this
/// connects to `postgres` — the database guaranteed to exist on a stock server —
/// carrying the target's credentials and TLS settings across unchanged.
async fn ensure_database_exists(options: &PgConnectOptions, name: &str) -> Result<()> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options.clone().database("postgres"))
        .await
        .context("failed to connect to the `postgres` maintenance database")?;

    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)")
            .bind(name)
            .fetch_one(&pool)
            .await
            .context("failed to check whether the database exists")?;

    if exists {
        return Ok(());
    }

    // `AssertSqlSafe` is sqlx 0.9's opt-out from the `&'static str` requirement on
    // query text. The audit it asks for is `quote_identifier`.
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "CREATE DATABASE {}",
        quote_identifier(name)
    )))
    .execute(&pool)
    .await
    .with_context(|| format!("failed to create database `{name}`"))?;

    tracing::info!(database = %name, "database created");
    Ok(())
}

/// Quotes a Postgres identifier for interpolation into a statement.
///
/// `CREATE DATABASE` takes an identifier, and an identifier cannot be a bind
/// parameter. The name comes from our own `DATABASE_URL` rather than user input,
/// but an escaping rule that depends on the caller is a rule that eventually
/// meets a caller who didn't read it.
fn quote_identifier(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_a_plain_identifier() {
        assert_eq!(quote_identifier("breathe"), "\"breathe\"");
    }

    /// Doubling is what stops an embedded `"` from closing the identifier early
    /// and letting the remainder of the name parse as SQL.
    #[test]
    fn doubles_embedded_quotes() {
        assert_eq!(quote_identifier(r#"a"b"#), r#""a""b""#);
    }
}
