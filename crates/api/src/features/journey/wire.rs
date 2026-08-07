//! The two boundaries every journey surface crosses.
//!
//! One is arithmetic: every number this feature serves is an aggregate over
//! `sessions` or `bolt_scores`, read back signed and sent unsigned. The other is
//! time: sessions carry instants, and the caller's UTC offset decides which
//! local day each one falls in.
//!
//! Both conversions are fallible, and deliberately so. These are the caller's
//! own figures and their own dates — a clamped count or a guessed instant is a
//! number somebody reads as theirs.

use std::fmt::Display;

use chrono::{DateTime, Utc};

use super::errors::JourneyError;

/// UTC offsets in use run from -12:00 to +14:00. Anything outside is not a time
/// zone.
const MIN_UTC_OFFSET_MINUTES: i32 = -12 * 60;
const MAX_UTC_OFFSET_MINUTES: i32 = 14 * 60;

/// Narrows an aggregate the schema already constrains to be non-negative.
///
/// Every `CHECK (… >= 0)` makes a negative value unreachable and no fold over
/// them can overflow the integer it is read into, so a value arriving here that
/// does not fit is corrupt data. Failing names the column; the alternatives this
/// replaced — `unwrap_or(0)` on a streak, `unwrap_or(u32::MAX)` on a session
/// count — put a number in front of somebody indistinguishable from one they
/// earned.
///
/// Generic in both directions rather than written once per pair. The counts
/// arrive as `i32`, `i64`, `u64` and `usize` depending on whether they were
/// summed, counted or measured, and land on `u32` or `u64` depending on the
/// field: a fixed signature would push a widening cast onto every call site,
/// and a cast is the thing this exists to remove.
pub fn counted<T, V>(field: &str, value: V) -> Result<T, JourneyError>
where
    V: TryInto<T> + Copy + Display,
{
    value.try_into().map_err(|_| {
        JourneyError::Inconsistent(format!("`{field}` is `{value}`, which is not a count"))
    })
}

/// Refuses an offset no time zone uses.
///
/// A client bug rather than a malicious value, but accepting it would silently
/// shift somebody's calendar days and therefore their streak.
pub fn validated_offset(minutes: i32) -> Result<i32, JourneyError> {
    if (MIN_UTC_OFFSET_MINUTES..=MAX_UTC_OFFSET_MINUTES).contains(&minutes) {
        return Ok(minutes);
    }

    Err(JourneyError::Invalid(format!(
        "`utc_offset_minutes` must be between {MIN_UTC_OFFSET_MINUTES} and {MAX_UTC_OFFSET_MINUTES}"
    )))
}

/// `google.protobuf.Timestamp` admits values no instant can hold — a negative
/// nanosecond count, a second count past the end of the calendar — so the
/// conversion is fallible and says which field failed.
pub fn timestamp_from_proto(
    stamp: &prost_types::Timestamp,
    field: &str,
) -> Result<DateTime<Utc>, JourneyError> {
    u32::try_from(stamp.nanos)
        .ok()
        .and_then(|nanos| DateTime::from_timestamp(stamp.seconds, nanos))
        .ok_or_else(|| JourneyError::Invalid(format!("`{field}` is not a valid timestamp")))
}

/// The other direction, which cannot fail.
///
/// The subsecond nanoseconds are clamped rather than checked: a leap second
/// reports more than a billion of them, which the proto type cannot carry, and
/// losing at most that one second is the right answer for a value being drawn on
/// a history strip.
pub fn timestamp_to_proto(instant: DateTime<Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: instant.timestamp(),
        nanos: i32::try_from(instant.timestamp_subsec_nanos()).unwrap_or(999_999_999),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The round trip a recent session makes on the way back out. Sub-second
    /// precision matters because a session at 23:59:59.9 local is the difference
    /// between a streak that held and one that paused.
    #[test]
    fn a_timestamp_survives_the_round_trip() {
        let instant =
            DateTime::from_timestamp(1_777_000_000, 123_456_789).expect("a representable instant");

        assert_eq!(
            timestamp_from_proto(&timestamp_to_proto(instant), "started_at")
                .expect("a converted timestamp is valid"),
            instant
        );
    }

    /// A negative nanosecond count is representable on the wire and is not an
    /// instant. Decoding it as one would put a session at an arbitrary moment.
    #[test]
    fn an_impossible_timestamp_fails_rather_than_being_guessed_at() {
        let malformed = prost_types::Timestamp {
            seconds: 1_777_000_000,
            nanos: -1,
        };

        assert!(matches!(
            timestamp_from_proto(&malformed, "started_at"),
            Err(JourneyError::Invalid(_))
        ));
    }

    /// The offsets that exist run from -12:00 to +14:00. Anything else is a
    /// client bug, and accepting it would silently shift somebody's calendar
    /// days.
    #[test]
    fn only_real_utc_offsets_are_accepted() {
        for minutes in [MIN_UTC_OFFSET_MINUTES, 0, 60, MAX_UTC_OFFSET_MINUTES] {
            assert!(validated_offset(minutes).is_ok());
        }
        for minutes in [MIN_UTC_OFFSET_MINUTES - 1, MAX_UTC_OFFSET_MINUTES + 1] {
            assert!(matches!(
                validated_offset(minutes),
                Err(JourneyError::Invalid(_))
            ));
        }
    }

    /// A count the domain cannot represent has to fail the call rather than
    /// arrive as a plausible number. The old shapes — a zeroed streak, a session
    /// count of four billion — are the caller's own figures, which are the ones
    /// they are most likely to believe.
    #[test]
    fn an_unrepresentable_count_fails_rather_than_being_rewritten() {
        assert_eq!(counted::<u32, _>("sessions", 42_i64).expect("in range"), 42);
        assert!(matches!(
            counted::<u32, _>("sessions", -1_i32),
            Err(JourneyError::Inconsistent(_))
        ));
        assert!(matches!(
            counted::<u32, _>("sessions", i64::from(u32::MAX) + 1),
            Err(JourneyError::Inconsistent(_))
        ));
        assert!(matches!(
            counted::<u64, _>("breaths", -1_i64),
            Err(JourneyError::Inconsistent(_))
        ));
    }
}
