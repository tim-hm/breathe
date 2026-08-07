//! What a purchase is, and the two identifiers Apple signs it against.

use chrono::{DateTime, Utc};

/// The app the App Store signs transactions for.
///
/// Checked against every submitted transaction: a signature that verifies
/// against Apple's root but names another app is a genuine receipt for somebody
/// else's product, which is exactly the token a determined caller would reach
/// for. It has to match `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`.
pub const BUNDLE_ID: &str = "xyz.holmie.breathe";

/// The one thing this app sells.
///
/// A constant rather than a set, because there is one subscription and the price
/// tier is not part of its identity. A second SKU makes this a slice; until then
/// a list of one would only invite the question of what happens when two match.
pub const PLUS_PRODUCT_ID: &str = "xyz.holmie.breathe.plus.yearly";

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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entitlement {
    pub tier: Tier,

    /// When the current Plus period ends. `None` whenever the tier is `Free`,
    /// including for a subscription that has lapsed — carrying a past date
    /// would invite a client to render an expiry for something nobody holds.
    pub expires_at: Option<DateTime<Utc>>,
}

impl Entitlement {
    /// Reads the stored expiry against a clock.
    ///
    /// `now` is a parameter rather than read here so the boundary is testable
    /// and so one request resolves every entitlement it touches against a single
    /// instant.
    pub fn resolve(plus_until: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Self {
        match plus_until {
            Some(until) if until > now => Self {
                tier: Tier::Plus,
                expires_at: Some(until),
            },
            _ => Self {
                tier: Tier::Free,
                expires_at: None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The expiry is the moment the entitlement ends, not the last moment it
    /// holds: an inclusive comparison would leave a lapsed subscriber on Plus
    /// for as long as the clock reported the exact expiry instant, and every
    /// stored value here comes from Apple to the millisecond.
    #[test]
    fn the_expiry_instant_is_already_lapsed() {
        let expiry = DateTime::from_timestamp(1_800_000_000, 0).expect("a valid instant");

        assert_eq!(Entitlement::resolve(Some(expiry), expiry).tier, Tier::Free);
        assert_eq!(
            Entitlement::resolve(Some(expiry), expiry - chrono::Duration::seconds(1)).tier,
            Tier::Plus
        );
    }

    /// A lapsed row drops its date on the way out. Anything else would have the
    /// client deciding for itself whether the timestamp beside `FREE` means
    /// something, which is the decision this type exists to make once.
    #[test]
    fn a_lapsed_subscription_carries_no_date() {
        let expiry = DateTime::from_timestamp(1_700_000_000, 0).expect("a valid instant");
        let later = expiry + chrono::Duration::days(1);

        assert_eq!(
            Entitlement::resolve(Some(expiry), later),
            Entitlement {
                tier: Tier::Free,
                expires_at: None
            }
        );
    }
}
