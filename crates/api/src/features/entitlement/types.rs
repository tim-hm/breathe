//! What a purchase is worth, once somebody has made one.

use chrono::{DateTime, Utc};

/// What a person may use.
///
/// Two states and no `Unknown`: everything that could make the answer uncertain
/// — an unreachable database, a transaction that failed to verify — resolves to
/// `Free`, which is the only safe direction to fail in when the thing being
/// gated costs money.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Free,
    Plus,
}

/// What the server believes about one person, at one moment.
///
/// Derived on read rather than stored, so a subscription that lapsed overnight
/// answers `Free` on the next call with nothing having run in between. There is
/// no renewal job and no expiry sweep for the same reason: the only thing that
/// would keep such a job honest is this calculation.
///
/// One field, private, and both readers derived from it — so "Plus with no
/// expiry" and "Free with one" are states this type cannot hold and no caller
/// has to be trusted not to construct.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entitlement {
    /// The expiry if it is still ahead, `None` otherwise. A lapsed date is
    /// dropped here rather than carried on: it is exactly the fact that makes
    /// the tier `Free`, and keeping it would invite a client to render an
    /// expiry for something nobody holds.
    expires_at: Option<DateTime<Utc>>,
}

impl Entitlement {
    /// Reads a stored expiry against a clock.
    ///
    /// `now` is a parameter rather than read here so the boundary is testable
    /// and so one request resolves every entitlement it touches against a single
    /// instant.
    pub fn resolve(plus_until: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Self {
        Self {
            expires_at: plus_until.filter(|until| *until > now),
        }
    }

    pub const fn tier(&self) -> Tier {
        if self.expires_at.is_some() {
            Tier::Plus
        } else {
            Tier::Free
        }
    }

    pub const fn expires_at(&self) -> Option<DateTime<Utc>> {
        self.expires_at
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The expiry is the moment the entitlement ends, not the last moment it
    /// holds: an inclusive comparison would leave a lapsed subscriber on Plus
    /// for as long as the clock reported the exact expiry instant, and every
    /// stored value here comes from Apple to the millisecond.
    ///
    /// The lapsed side also pins that the date goes with the tier, which is the
    /// one thing a caller could otherwise read and render.
    #[test]
    fn the_expiry_instant_is_already_lapsed() {
        let expiry = DateTime::from_timestamp(1_800_000_000, 0).expect("a valid instant");

        let lapsed = Entitlement::resolve(Some(expiry), expiry);
        assert_eq!(lapsed.tier(), Tier::Free);
        assert_eq!(lapsed.expires_at(), None);

        let live = Entitlement::resolve(Some(expiry), expiry - chrono::Duration::seconds(1));
        assert_eq!(live.tier(), Tier::Plus);
        assert_eq!(live.expires_at(), Some(expiry));
    }
}
