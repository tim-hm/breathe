//! Business logic — picks a board, resolves who it is drawn from, and converts
//! the ranking onto the wire.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use sqlx::PgPool;

use super::super::errors::JourneyError;
use super::super::wire::{counted, validated_offset};
use super::repository::{self, LeaderboardRow};
use super::types::{LeaderboardBoard, LeaderboardScope};
use crate::features::profile::service as profile;
use crate::identity::UserId;
use crate::proto::breathe::v1 as pb;

/// How many named entries a board returns.
const LEADERBOARD_LIMIT: i64 = 20;

/// A board's leading entries, plus where the caller stands on it.
///
/// The opt-in runs one way: only people who have chosen a display name appear in
/// `entries`, and everyone with a score is counted in the ranking. Somebody
/// anonymous is therefore invisible to others and still knows their own
/// position, which is what makes the boards worth opting into rather than a wall
/// to climb first.
///
/// The age-band scope needs a birth-year band the caller may never have given.
/// That is a `FAILED_PRECONDITION` rather than a malformed request: the client's
/// answer is to offer the decade question, not to correct a field.
pub async fn get_leaderboard(
    pool: &PgPool,
    user_id: UserId,
    request: pb::GetLeaderboardRequest,
) -> Result<pb::GetLeaderboardResponse, JourneyError> {
    let board = board_from_proto(request.board)?;
    let scope = scope_from_proto(request.scope)?;

    let band = match scope {
        LeaderboardScope::Global => None,
        LeaderboardScope::AgeBand => Some(
            profile::birth_year_band(pool, user_id)
                .await?
                .ok_or(JourneyError::AgeBandUnset)?,
        ),
    };

    let rows = match board {
        LeaderboardBoard::Streak => {
            let offset = validated_offset(request.utc_offset_minutes)?;
            repository::streak_board(pool, user_id, band, LEADERBOARD_LIMIT, offset).await?
        }
        LeaderboardBoard::Minutes30d => {
            repository::minutes_board(pool, user_id, band, LEADERBOARD_LIMIT).await?
        }
        LeaderboardBoard::Bolt => {
            repository::bolt_board(pool, user_id, band, LEADERBOARD_LIMIT).await?
        }
    };

    to_leaderboard_response(user_id, rows)
}

/// Splits the one board query into the part everybody sees and the part only the
/// caller does.
///
/// The caller's own row arrives alongside the leading entries, and it may or may
/// not be one of them — somebody in the top twenty appears once, in both roles.
///
/// Every narrowing here is fallible. A rank or a value the wire cannot carry
/// fails the call rather than dropping that person from the board or zeroing
/// their score: a board short by one row is indistinguishable from a board with
/// one fewer participant, and a zero reads as "they have not practised".
fn to_leaderboard_response(
    user_id: UserId,
    rows: Vec<LeaderboardRow>,
) -> Result<pb::GetLeaderboardResponse, JourneyError> {
    let caller = match rows.iter().find(|row| row.user_id == user_id.0) {
        Some(row) => Some(pb::LeaderboardStanding {
            rank: Some(counted("rank", row.rank)?),
            value: counted("value", row.value)?,
            listed: row.display_name.is_some(),
        }),
        None => None,
    };

    let entries = rows
        .into_iter()
        .filter(|row| row.on_board)
        .map(|row| {
            // `on_board` is `display_name IS NOT NULL AND …`, so an absent name
            // here is the query disagreeing with itself rather than an anonymous
            // participant.
            let display_name = row.display_name.ok_or_else(|| {
                JourneyError::Inconsistent(format!(
                    "board entry for `{}` is listed with no display name",
                    row.user_id
                ))
            })?;

            Ok(pb::LeaderboardEntry {
                rank: counted("rank", row.rank)?,
                display_name,
                value: counted("value", row.value)?,
            })
        })
        .collect::<Result<Vec<_>, JourneyError>>()?;

    Ok(pb::GetLeaderboardResponse {
        entries,
        // Present even when the caller has nothing to rank, so the client can
        // tell "no score yet" from "no answer" without a second field.
        caller: Some(caller.unwrap_or(pb::LeaderboardStanding {
            rank: None,
            value: 0,
            listed: false,
        })),
    })
}

fn board_from_proto(raw: i32) -> Result<LeaderboardBoard, JourneyError> {
    match pb::LeaderboardBoard::try_from(raw) {
        Ok(pb::LeaderboardBoard::Streak) => Ok(LeaderboardBoard::Streak),
        Ok(pb::LeaderboardBoard::Minutes30d) => Ok(LeaderboardBoard::Minutes30d),
        Ok(pb::LeaderboardBoard::Bolt) => Ok(LeaderboardBoard::Bolt),
        Ok(pb::LeaderboardBoard::Unspecified) | Err(_) => Err(JourneyError::Invalid(format!(
            "`{raw}` is not a board this server knows"
        ))),
    }
}

fn scope_from_proto(raw: i32) -> Result<LeaderboardScope, JourneyError> {
    match pb::LeaderboardScope::try_from(raw) {
        Ok(pb::LeaderboardScope::Global) => Ok(LeaderboardScope::Global),
        Ok(pb::LeaderboardScope::AgeBand) => Ok(LeaderboardScope::AgeBand),
        Ok(pb::LeaderboardScope::Unspecified) | Err(_) => Err(JourneyError::Invalid(format!(
            "`{raw}` is not a scope this server knows"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    fn row(rank: i64, value: i32, display_name: Option<&str>) -> LeaderboardRow {
        LeaderboardRow {
            user_id: Uuid::from_u128(u128::try_from(rank).unwrap_or(0)),
            display_name: display_name.map(ToOwned::to_owned),
            value,
            rank,
            on_board: display_name.is_some(),
        }
    }

    /// Every board and scope the proto can carry has to be either a real case or
    /// a rejection — a zero value silently becoming STREAK would answer a
    /// question nobody asked.
    #[test]
    fn an_unspecified_board_or_scope_is_refused() {
        assert!(matches!(
            board_from_proto(pb::LeaderboardBoard::Unspecified as i32),
            Err(JourneyError::Invalid(_))
        ));
        assert!(matches!(
            scope_from_proto(pb::LeaderboardScope::Unspecified as i32),
            Err(JourneyError::Invalid(_))
        ));
        assert!(board_from_proto(pb::LeaderboardBoard::Bolt as i32).is_ok());
        assert!(scope_from_proto(pb::LeaderboardScope::AgeBand as i32).is_ok());
    }

    /// A row the wire cannot carry fails the call. The shape this replaced
    /// dropped that person from the board and zeroed the score, and neither is
    /// falsifiable from a client: a board short by one row looks exactly like a
    /// board with one fewer participant.
    #[test]
    fn a_row_that_does_not_fit_fails_the_board_rather_than_shortening_it() {
        let caller = UserId(Uuid::from_u128(1));

        assert!(matches!(
            to_leaderboard_response(caller, vec![row(i64::from(u32::MAX) + 1, 5, Some("Ada"))]),
            Err(JourneyError::Inconsistent(_))
        ));
        assert!(matches!(
            to_leaderboard_response(caller, vec![row(1, -5, Some("Ada"))]),
            Err(JourneyError::Inconsistent(_))
        ));

        let listed = to_leaderboard_response(caller, vec![row(1, 5, Some("Ada"))])
            .expect("a representable row is served");
        assert_eq!(listed.entries.len(), 1);
    }
}
