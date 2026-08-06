//! Boot-time configuration.
//!
//! Only two values come from the environment: `BREATHE_ENV` and `DATABASE_URL`.
//! Everything else is *derived* from the environment name (CLAUDE.md §1.4–1.5).
//! The reason is that every environment variable is a value that can differ
//! between a developer's machine and a deployment without anything noticing —
//! a derived value cannot drift, because there is only one of it.

use anyhow::{Context, Result};

/// Which deployment this process is. Chosen from `BREATHE_ENV`; everything
/// environment-dependent is a `match` on this rather than another variable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Environment {
    Dev,
    Production,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub environment: Environment,
    pub database_url: String,
    pub port: u16,
}

impl Environment {
    /// Every variant, so parsing and the "must be one of" error message both
    /// derive from `as_str` rather than repeating it.
    ///
    /// The array is what makes adding a variant a compile error here *and* a
    /// correct parse: a `match` on `&str` in `load` would accept a new variant
    /// silently and leave the error text quietly lying about what it accepts.
    const ALL: [Self; 2] = [Self::Dev, Self::Production];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Dev => "dev",
            Self::Production => "production",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|env| env.as_str() == value)
    }
}

impl Config {
    /// Human-readable logs in dev, JSON everywhere else.
    ///
    /// JSON is unreadable in a terminal and mandatory in a log aggregator, and
    /// which of those is reading is exactly what `Environment` already knows.
    pub const fn wants_json_logs(&self) -> bool {
        matches!(self.environment, Environment::Production)
    }

    /// Whether cleartext HTTP from a simulator or a browser on this machine
    /// should be permitted a permissive CORS policy.
    pub const fn is_local(&self) -> bool {
        matches!(self.environment, Environment::Dev)
    }
}

/// breathe owns 18100–18199; this is the first of them. See docs/contributing.md
/// for why the range starts here.
const DEFAULT_PORT: u16 = 18100;

pub fn load() -> Result<Config> {
    let environment = match std::env::var("BREATHE_ENV") {
        Ok(value) => Environment::parse(&value).with_context(|| {
            format!(
                "BREATHE_ENV must be one of {:?}, got `{value}`",
                Environment::ALL.map(Environment::as_str)
            )
        })?,
        // Dev is the default because an unset variable means a developer's
        // machine. A deployment that forgets to set it gets dev's permissive
        // CORS and pretty logs, which is loud enough to notice immediately and
        // is not itself a security boundary.
        Err(std::env::VarError::NotPresent) => Environment::Dev,
        Err(e) => return Err(e).context("BREATHE_ENV is not valid UTF-8"),
    };

    let database_url = std::env::var("DATABASE_URL").context(
        "DATABASE_URL is not set — run through `mise run dev`, which supplies it (CLAUDE.md §3)",
    )?;

    Ok(Config {
        environment,
        database_url,
        port: DEFAULT_PORT,
    })
}
