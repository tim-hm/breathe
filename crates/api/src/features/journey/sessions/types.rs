//! Where a page of session history stopped, and the bounded practice snapshot
//! the assistant reads instead of rows.

use chrono::{DateTime, SecondsFormat, Utc};
use uuid::Uuid;

use super::super::bolt::types::BoltSnapshot;
use super::super::errors::JourneyError;
use super::repository::SessionRow;

/// How far back the practice snapshot looks, in whole days ending now.
///
/// Thirty days of UTC, deliberately without a client offset: the snapshot is
/// prompt input, not a screen, and it feeds offset-insensitive phrasing ("on 11
/// of the last 30 days") rather than streak-precise claims. A window that
/// shifted with the caller's time zone would change the numbers without
/// changing the practice — and no offset travels on the assistant's requests.
///
/// A `u16` so both consumers convert losslessly: the queries widen it to the
/// `int` `make_interval` takes, and [`PracticeSnapshot::window_days`] to `u32`.
pub const PRACTICE_WINDOW_DAYS: u16 = 30;

/// How many techniques the snapshot names individually.
///
/// Six covers everything a person deliberately practises; past that the entries
/// are one-offs and typos, and each would cost a prompt line. The cap bounds
/// the lines, not the arithmetic — the totals still count every session.
pub const MAX_SNAPSHOT_TECHNIQUES: usize = 6;

/// What one person has practised recently, folded down to what a prompt can
/// afford.
///
/// A bounded aggregate rather than rows, by design: the assistant renders this
/// as a handful of prompt lines, so everything here is already summed, capped,
/// and free of instants. `by_technique` keeps the busiest
/// [`MAX_SNAPSHOT_TECHNIQUES`] entries while the totals count everything, so a
/// long tail widens no prompt.
#[derive(Debug, PartialEq, Eq)]
pub struct PracticeSnapshot {
    /// The window the aggregates cover — [`PRACTICE_WINDOW_DAYS`], carried so a
    /// consumer can phrase "of the last N days" without importing the constant.
    pub window_days: u32,
    pub sessions: u32,
    pub minutes: u32,
    /// Distinct UTC days with at least one session in the window.
    pub active_days: u32,
    /// Busiest first. The slugs are client-supplied free text with no foreign
    /// key — resolving them against the catalogue is the consumer's business,
    /// because only it knows what to do with one it cannot resolve.
    pub by_technique: Vec<TechniquePractice>,
    /// `None` before they have ever taken the test.
    pub bolt: Option<BoltSnapshot>,
}

/// One technique's share of the window.
#[derive(Debug, PartialEq, Eq)]
pub struct TechniquePractice {
    pub technique_slug: String,
    pub sessions: u32,
    pub minutes: u32,
}

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
