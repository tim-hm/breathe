//! Boot-time configuration.
//!
//! Three values come from the environment: `BREATHE_ENV`, `DATABASE_URL`, and
//! the optional `OPENROUTER_API_KEY`. Everything else is *derived* from the
//! environment name (CLAUDE.md §1.4–1.5). The reason is that every environment
//! variable is a value that can differ between a developer's machine and a
//! deployment without anything noticing — a derived value cannot drift, because
//! there is only one of it.
//!
//! The third is a secret, which is the one thing the principle admits, and it
//! is the *only* assistant value that comes from outside: which provider and
//! which model are constants below, so a laptop and a deployment cannot end up
//! talking to different models without anybody noticing.

use std::fmt;
use std::str::FromStr;

use anyhow::{Context, Result};
use sqlx::postgres::PgConnectOptions;

/// Which deployment this process is. Chosen from `BREATHE_ENV`; everything
/// environment-dependent is a `match` on this rather than another variable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Environment {
    Dev,
    Production,
}

#[derive(Clone)]
pub struct Config {
    pub environment: Environment,
    pub database_url: String,
    pub port: u16,
    /// The assistant's provider key, or `None` where nobody supplied one.
    ///
    /// Optional on purpose: a fresh clone, a CI run, and the integration tests
    /// all work without it, and the assistant answers from its rules instead.
    /// The key never leaves this process — it is why the model is called from
    /// the server rather than the app at all.
    pub openrouter_api_key: Option<String>,
}

/// Hand-written because the derive published both credentials.
///
/// `database_url` carries the Postgres password inline in the deployed compose
/// file and `openrouter_api_key` is the provider key, and `AppState` holds the
/// whole struct — so one `tracing::error!(?config, …)` or one
/// `.context(format!("{config:?}"))` would have put both in the production JSON
/// stream permanently, with nothing failing to compile. The field doc above
/// claims the key never leaves this process; this impl is what makes it true.
impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("environment", &self.environment)
            .field("database_url", &redacted(&self.database_url))
            .field("port", &self.port)
            .field(
                "openrouter_api_key",
                &self.openrouter_api_key.as_ref().map(|_| REDACTED),
            )
            .finish()
    }
}

const REDACTED: &str = "<redacted>";

/// Where the pool points, with the credentials taken out.
///
/// Parsed rather than cut down with string surgery: the parser is the thing
/// that knows which part is the password, and a hand-written cut would
/// eventually meet a URL shaped differently from the one it was written
/// against. Note that sqlx's own `to_url_lossy` is not the shortcut it looks
/// like — it writes the password back in. An unparseable value redacts whole,
/// because a `Debug` impl has nowhere to report a failure and guessing is
/// exactly how a password reaches a log.
fn redacted(database_url: &str) -> String {
    PgConnectOptions::from_str(database_url).map_or_else(
        |_| REDACTED.to_owned(),
        |options| {
            format!(
                "{}:{}/{}",
                options.get_host(),
                options.get_port(),
                options.get_database().unwrap_or_default()
            )
        },
    )
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

    /// Whether this process is a developer's machine rather than a deployment.
    ///
    /// Two callers, and they want the same answer for different reasons:
    /// `cors_layer` permits cleartext HTTP from a simulator or a browser here,
    /// and `grpc::build_services` registers reflection here. Both are surfaces a
    /// deployment must not carry, so a third caller almost certainly belongs to
    /// the same set — check that it does before adding one.
    pub const fn is_local(&self) -> bool {
        matches!(self.environment, Environment::Dev)
    }
}

/// breathe owns 18100–18199; this is the first of them. See docs/contributing.md
/// for why the range starts here.
const DEFAULT_PORT: u16 = 18100;

/// Where the assistant's model calls go.
///
/// `OpenRouter` rather than a provider directly: it fronts every model behind one
/// OpenAI-shaped API, so trying a different model is the constant below rather
/// than a new client. No trailing slash — the paths appended to it supply one.
pub const OPENROUTER_BASE_URL: &str = "https://openrouter.ai/api/v1";

/// The model the assistant asks.
///
/// A constant, not a variable, for the reason the whole module exists: a model
/// id that could differ between a laptop and a deployment would make "the
/// assistant sounds different in production" a thing nobody could see.
///
/// The leading `~` **is part of the id** — it is how `OpenRouter` names a
/// floating alias, and this one tracks the newest Anthropic Haiku. Haiku
/// because both RPCs are short, structured, and latency-sensitive, and because
/// per-call cost is what makes a generous free-tier quota possible at all.
/// Verify a replacement against `GET https://openrouter.ai/api/v1/models`,
/// which needs no key.
pub const OPENROUTER_MODEL_ID: &str = "~anthropic/claude-haiku-latest";

pub fn load() -> Result<Config> {
    let environment = environment_from(std::env::var("BREATHE_ENV"))?;

    let database_url = std::env::var("DATABASE_URL").context(
        "DATABASE_URL is not set — run through `mise run dev`, which supplies it (CLAUDE.md §3)",
    )?;

    Ok(Config {
        environment,
        database_url,
        port: DEFAULT_PORT,
        openrouter_api_key: secret_from(std::env::var("OPENROUTER_API_KEY")),
    })
}

/// Reads an optional secret, treating blank as absent.
///
/// A variable set to the empty string is what a deployment template that forgot
/// to fill it in produces, and it must mean the same as not setting it: an
/// empty bearer token would otherwise reach the provider and come back as a
/// 401 on every call for as long as nobody looked.
fn secret_from(var: Result<String, std::env::VarError>) -> Option<String> {
    var.ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

/// Interprets the raw `BREATHE_ENV` lookup. Split from `load` so the branching
/// is testable without mutating the process environment.
fn environment_from(var: Result<String, std::env::VarError>) -> Result<Environment> {
    match var {
        Ok(value) => Environment::parse(&value).with_context(|| {
            format!(
                "BREATHE_ENV must be one of {:?}, got `{value}`",
                Environment::ALL.map(Environment::as_str)
            )
        }),
        // Dev is the default because an unset variable means a developer's
        // machine. A deployment that forgets to set it gets dev's permissive
        // CORS, pretty logs, and gRPC reflection — so this fallback does sit in
        // front of things a deployment should not expose, and the Caddyfile
        // declines to proxy the reflection path rather than trusting it alone.
        Err(std::env::VarError::NotPresent) => Ok(Environment::Dev),
        Err(e) => Err(e).context("BREATHE_ENV is not valid UTF-8"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_environment_name() {
        for environment in Environment::ALL {
            let parsed = environment_from(Ok(environment.as_str().to_owned()));
            assert_eq!(parsed.expect("a known name parses"), environment);
        }
    }

    #[test]
    fn defaults_to_dev_when_unset() {
        let parsed = environment_from(Err(std::env::VarError::NotPresent));
        assert_eq!(parsed.expect("absence is not an error"), Environment::Dev);
    }

    /// A template that was never filled in sets the variable to nothing, and
    /// that has to mean "no key" — not "send an empty bearer token", which
    /// fails every call with a 401 nobody is watching for.
    #[test]
    fn a_blank_secret_is_no_secret() {
        for blank in [String::new(), "   ".to_owned(), "\n".to_owned()] {
            assert_eq!(secret_from(Ok(blank)), None);
        }

        assert_eq!(secret_from(Err(std::env::VarError::NotPresent)), None);
        assert_eq!(
            secret_from(Ok("  sk-or-v1-example  ".to_owned())),
            Some("sk-or-v1-example".to_owned()),
            "a key pasted with whitespace around it is still that key"
        );
    }

    /// The check that survives the next editor: whatever else the impl prints,
    /// neither credential may appear. Re-deriving `Debug` fails this.
    #[test]
    fn debug_redacts_both_credentials() {
        let config = Config {
            environment: Environment::Production,
            database_url: "postgres://postgres:hunter2@db:5432/breathe?sslmode=disable".to_owned(),
            port: DEFAULT_PORT,
            openrouter_api_key: Some("sk-or-v1-example".to_owned()),
        };

        let rendered = format!("{config:?}");
        assert!(!rendered.contains("hunter2"), "{rendered}");
        assert!(!rendered.contains("sk-or-v1-example"), "{rendered}");
        assert!(
            rendered.contains("db:5432/breathe"),
            "the host and database name are the part worth keeping: {rendered}"
        );
    }

    /// The error text derives from `Environment::ALL`, so it names every
    /// accepted value — this pins that it can't quietly go stale.
    #[test]
    fn an_unknown_name_lists_the_accepted_values() {
        let error = environment_from(Ok("staging".to_owned())).expect_err("staging is not a name");
        let message = format!("{error:#}");
        for environment in Environment::ALL {
            assert!(message.contains(environment.as_str()));
        }
        assert!(message.contains("staging"));
    }
}
