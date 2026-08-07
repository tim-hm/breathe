//! What a purchase is worth, once somebody has made one.

use chrono::{DateTime, Utc};

/// What a person may use.
///
/// Ordered, and the ordering is the type's job: every tier contains the one
/// below it, so every gate in the codebase reads `>= Tier::Coach` rather than
/// enumerating which tiers qualify. Adding a tier above `Coach` then changes no
/// comparison anywhere.
///
/// No `Unknown`. Everything that could make the answer uncertain — an
/// unreachable database, a transaction that failed to verify, a product id this
/// build has never heard of — resolves to `Free`, which is the only safe
/// direction to fail in when the thing being gated costs money.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Free,

    /// The catalogue, and everything the app does that costs nothing per use.
    Plus,

    /// Plus, and the language model behind the assistant.
    Coach,
}

/// Mirrors the `subscription_tier` Postgres enum, which holds only the tiers
/// somebody can buy.
///
/// Separate from [`Tier`] rather than folded into it, and the separation is the
/// point: `Free` is not a subscription, so a column that could store it would
/// admit a row claiming a free subscription that expires. The database's enum
/// therefore has two labels and this type has two variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "subscription_tier", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SubscriptionTier {
    Plus,
    Coach,
}

impl From<SubscriptionTier> for Tier {
    fn from(tier: SubscriptionTier) -> Self {
        match tier {
            SubscriptionTier::Plus => Self::Plus,
            SubscriptionTier::Coach => Self::Coach,
        }
    }
}

/// What the server believes about one person, at one moment.
///
/// Derived on read rather than stored, so a subscription that lapsed overnight
/// answers `Free` on the next call with nothing having run in between. There is
/// no renewal job and no expiry sweep for the same reason: the only thing that
/// would keep such a job honest is this calculation.
///
/// One private field holding both halves or neither, so "Coach with no expiry"
/// and "Free with one" are states this type cannot hold and no caller has to be
/// trusted not to construct.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entitlement {
    /// The subscription if it is still running, `None` otherwise. A lapsed pair
    /// is dropped here rather than carried on: it is exactly the fact that makes
    /// the tier `Free`, and keeping it would invite a client to render an expiry
    /// for something nobody holds.
    active: Option<(SubscriptionTier, DateTime<Utc>)>,
}

impl Entitlement {
    /// Reads a stored subscription against a clock.
    ///
    /// Takes the two columns as they come out of the database — either both
    /// present or both null, which the `users_subscription_is_whole` constraint
    /// guarantees — and treats any other combination as no subscription. That
    /// last part is not defensive clutter: it is what makes the return type
    /// unable to express the half-written state the constraint forbids.
    ///
    /// `now` is a parameter rather than read here so the boundary is testable
    /// and so one request resolves every entitlement it touches against a single
    /// instant.
    pub fn resolve(
        tier: Option<SubscriptionTier>,
        until: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            active: tier.zip(until).filter(|(_, until)| *until > now),
        }
    }

    pub fn tier(&self) -> Tier {
        self.active.map_or(Tier::Free, |(tier, _)| Tier::from(tier))
    }

    pub fn expires_at(&self) -> Option<DateTime<Utc>> {
        self.active.map(|(_, until)| until)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn instant(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("a valid instant")
    }

    /// The expiry is the moment the entitlement ends, not the last moment it
    /// holds: an inclusive comparison would leave a lapsed subscriber on Coach
    /// for as long as the clock reported the exact expiry instant, and every
    /// stored value here comes from Apple to the millisecond.
    ///
    /// The lapsed side also pins that the date goes with the tier, which is the
    /// one thing a caller could otherwise read and render.
    #[test]
    fn the_expiry_instant_is_already_lapsed() {
        let expiry = instant(1_800_000_000);

        let lapsed = Entitlement::resolve(Some(SubscriptionTier::Coach), Some(expiry), expiry);
        assert_eq!(lapsed.tier(), Tier::Free);
        assert_eq!(lapsed.expires_at(), None);

        let live = Entitlement::resolve(
            Some(SubscriptionTier::Coach),
            Some(expiry),
            expiry - chrono::Duration::seconds(1),
        );
        assert_eq!(live.tier(), Tier::Coach);
        assert_eq!(live.expires_at(), Some(expiry));
    }

    /// Every gate in the codebase is a comparison rather than a match, so the
    /// ordering is load-bearing rather than incidental. A Coach subscriber must
    /// satisfy a Plus gate; a Plus subscriber must not satisfy a Coach one.
    #[test]
    fn a_higher_tier_satisfies_a_lower_gate() {
        assert!(Tier::Coach > Tier::Plus);
        assert!(Tier::Plus > Tier::Free);
        assert!(Tier::Coach >= Tier::Coach);
        assert!(Tier::Plus < Tier::Coach);
    }
}
