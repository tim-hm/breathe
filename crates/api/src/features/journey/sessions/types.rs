//! Where a page of session history stopped.

use chrono::{DateTime, SecondsFormat, Utc};
use uuid::Uuid;

use super::super::errors::JourneyError;
use super::repository::SessionRow;

/// The separator between the two halves of an encoded cursor.
///
/// A vertical bar occurs in neither an RFC 3339 instant nor a hyphenated UUID,
/// so `split_once` cannot be fooled by a well-formed token.
const CURSOR_SEPARATOR: char = '|';

/// The position of the last session a page returned.
///
/// Both columns, because `started_at` alone is not unique: two sessions recorded
/// in the same nanosecond would let a page boundary fall between them, dropping
/// one and repeating the other — which on the restore path is silent data loss
/// of exactly the kind paging exists to end.
///
/// A keyset rather than an offset. A restore walks the whole archive, and an
/// `OFFSET` gets slower with every page while a seek on the primary ordering
/// stays flat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionCursor {
    pub started_at: DateTime<Utc>,
    pub client_session_id: Uuid,
}

impl SessionCursor {
    /// The token as it travels, which is the server's business and not the
    /// client's.
    ///
    /// Legible rather than encrypted: it names one of the caller's own sessions,
    /// and every query it feeds is already scoped to `user_id`, so a forged
    /// cursor can only move somebody around their own history.
    pub fn encode(&self) -> String {
        format!(
            "{}{CURSOR_SEPARATOR}{}",
            self.started_at.to_rfc3339_opts(SecondsFormat::Nanos, true),
            self.client_session_id
        )
    }

    /// Reads a token back, refusing anything this server did not mint.
    ///
    /// An `Invalid` rather than a silent restart from the first page: a client
    /// that sends a token it made up is walking a history it will never finish,
    /// and a fresh first page would look to it exactly like progress.
    pub fn decode(token: &str) -> Result<Self, JourneyError> {
        let malformed =
            || JourneyError::Invalid(format!("`page_token` `{token}` is not one we issued"));

        let (started_at, client_session_id) =
            token.split_once(CURSOR_SEPARATOR).ok_or_else(malformed)?;

        Ok(Self {
            started_at: DateTime::parse_from_rfc3339(started_at)
                .map_err(|_| malformed())?
                .with_timezone(&Utc),
            client_session_id: Uuid::parse_str(client_session_id).map_err(|_| malformed())?,
        })
    }
}

impl From<&SessionRow> for SessionCursor {
    fn from(row: &SessionRow) -> Self {
        Self {
            started_at: row.started_at,
            client_session_id: row.client_session_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The restore path's whole correctness rests on a token surviving the trip
    /// to a client and back, sub-second precision included — a cursor rounded to
    /// the second would re-serve or skip every session sharing that second.
    #[test]
    fn a_cursor_survives_the_round_trip() {
        let cursor = SessionCursor {
            started_at: DateTime::from_timestamp(1_777_000_000, 123_456_789)
                .expect("a representable instant"),
            client_session_id: Uuid::from_u128(42),
        };

        assert_eq!(
            SessionCursor::decode(&cursor.encode()).expect("a token we issued decodes"),
            cursor
        );
    }

    /// A token this server did not mint is refused rather than treated as "start
    /// again": a restore that silently restarts looks like progress and never
    /// terminates.
    #[test]
    fn a_token_we_did_not_issue_is_refused() {
        for token in [
            "",
            "not-a-token",
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:00:00Z|not-a-uuid",
            "yesterday|00000000-0000-4000-8000-000000000001",
        ] {
            assert!(
                matches!(SessionCursor::decode(token), Err(JourneyError::Invalid(_))),
                "`{token}` should be refused"
            );
        }
    }
}
