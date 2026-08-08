//! Boot-time configuration.
//!
//! Two values come from the environment: `OND_ENV` and `DATABASE_URL`.
//! Everything else is *derived* from the environment name (CLAUDE.md §1.4–1.5).
//! The reason is that every environment variable is a value that can differ
//! between a developer's machine and a deployment without anything noticing — a
//! derived value cannot drift, because there is only one of it.
//!
//! Nothing here configures the assistant. Its credentials are the EC2 instance
//! profile, which the AWS SDK finds through its default credential chain
//! without being told; its region and its model are the constants below. So the
//! variable the principle would have admitted — a provider key — does not
//! exist, and a laptop and a deployment cannot end up talking to different
//! models without anybody noticing.

use std::fmt;
use std::str::FromStr;

use anyhow::{Context, Result};
use sqlx::postgres::PgConnectOptions;

/// Which deployment this process is. Chosen from `OND_ENV`; everything
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
}

/// Hand-written because the derive published a credential.
///
/// `database_url` carries the Postgres password inline in the deployed compose
/// file, and `AppState` holds the whole struct — so one
/// `tracing::error!(?config, …)` or one `.context(format!("{config:?}"))` would
/// have put it in the production JSON stream permanently, with nothing failing
/// to compile.
impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("environment", &self.environment)
            .field("database_url", &redacted(&self.database_url))
            .field("port", &self.port)
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

/// önd owns 18100–18199; this is the first of them. See docs/contributing.md
/// for why the range starts here.
const DEFAULT_PORT: u16 = 18100;

/// The app, as Apple names it.
///
/// Two surfaces check it and both have to mean the same app: the `bundleId` on
/// an App Store signed transaction (`entitlement::verifier::appstore`) and the
/// `aud` of a Sign in with Apple identity token
/// (`account::verifier::apple`). A signature that verifies against Apple and
/// names another app is a genuine token for somebody else's product, which is
/// exactly what a determined caller would reach for — so the value is the check
/// rather than a label.
///
/// A constant here rather than a variable, for the reason the whole module
/// exists, and in one place rather than one per verifier because a build that
/// honoured App Store receipts for one app and sign-ins for another is a state
/// no test would think to look for. It has to match `PRODUCT_BUNDLE_IDENTIFIER`
/// in `ios/project.yml`.
pub const BUNDLE_ID: &str = "xyz.holmie.ond";

/// The AWS region the assistant's calls are signed for and sent to.
///
/// The box itself is in London, so a coach request reaches Bedrock's regional
/// endpoint without leaving the region the rest of the deployment lives in.
/// Where it goes *after* that is the inference profile's business — see below.
///
/// A constant rather than `AWS_REGION`, for the reason the whole module exists:
/// a region that could differ between a laptop and the deployment would route
/// coach traffic somewhere `web/privacy.html` does not describe.
pub const BEDROCK_REGION: &str = "eu-west-2";

/// The model the assistant asks, named as an **EU cross-region inference
/// profile**.
///
/// The `eu.` prefix is the profile, not a region tag. Bedrock forwards each
/// call to one of the profile's destination regions for capacity, which is why
/// `web/privacy.html` says coach requests are processed across Amazon's EU
/// regions rather than naming one — and why the IAM policy in `infra/main.tf`
/// has to grant the underlying foundation model in *every* destination region
/// alongside the profile itself. A policy naming only the profile passes a plan
/// and then fails at invoke time.
///
/// Haiku because both RPCs are short, structured, and latency-sensitive, and
/// because per-call cost is what makes a generous free-tier quota possible at
/// all.
///
/// **Standing constraint on replacing this.** `web/privacy.html` states that
/// what a person types is neither retained nor used to train any model. A model
/// whose Bedrock listing requires provider data sharing — one whose
/// `allowed_modes` does not offer `none` — makes that page untrue the moment it
/// is adopted. Such a model cannot be put here without changing that page in
/// the same commit.
pub const BEDROCK_MODEL_ID: &str = "eu.anthropic.claude-haiku-4-5-20251001-v1:0";

pub fn load() -> Result<Config> {
    let environment = environment_from(std::env::var("OND_ENV"))?;

    let database_url = std::env::var("DATABASE_URL").context(
        "DATABASE_URL is not set — run through `mise run dev`, which supplies it (CLAUDE.md §3)",
    )?;

    Ok(Config {
        environment,
        database_url,
        port: DEFAULT_PORT,
    })
}

/// Interprets the raw `OND_ENV` lookup. Split from `load` so the branching
/// is testable without mutating the process environment.
fn environment_from(var: Result<String, std::env::VarError>) -> Result<Environment> {
    match var {
        Ok(value) => Environment::parse(&value).with_context(|| {
            format!(
                "OND_ENV must be one of {:?}, got `{value}`",
                Environment::ALL.map(Environment::as_str)
            )
        }),
        // Dev is the default because an unset variable means a developer's
        // machine. A deployment that forgets to set it gets dev's permissive
        // CORS, pretty logs, and gRPC reflection — so this fallback does sit in
        // front of things a deployment should not expose, and the Caddyfile
        // declines to proxy the reflection path rather than trusting it alone.
        Err(std::env::VarError::NotPresent) => Ok(Environment::Dev),
        Err(e) => Err(e).context("OND_ENV is not valid UTF-8"),
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

    /// The check that survives the next editor: whatever else the impl prints,
    /// the Postgres password may not appear. Re-deriving `Debug` fails this.
    #[test]
    fn debug_redacts_the_database_password() {
        let config = Config {
            environment: Environment::Production,
            database_url: "postgres://postgres:hunter2@db:5432/ond?sslmode=disable".to_owned(),
            port: DEFAULT_PORT,
        };

        let rendered = format!("{config:?}");
        assert!(!rendered.contains("hunter2"), "{rendered}");
        assert!(
            rendered.contains("db:5432/ond"),
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
