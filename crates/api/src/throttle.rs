//! What one caller may spend, and the two budgets that bound it.
//!
//! Nothing in front of this process rations anything: `infra/box/Caddyfile`
//! reverse-proxies without a limit, and stock `caddy:2` has none to switch on —
//! its rate limiter is an `xcaddy` plugin, which would mean a second image and a
//! second `docker save | ssh docker load` leg in a deploy that deliberately has
//! one of each (docs/deployment.md). So the ration lives here, where it ships
//! with the binary it protects and `tests/e2e` can drive it.
//!
//! Two budgets rather than one, because the two things worth bounding grow at
//! different rates. [`Throttle::spend_request`] bounds how hard a caller may
//! work the boards, whose queries read the fastest-growing table in the schema.
//! [`Throttle::spend_new_identity`] bounds how many `users` rows a caller may
//! bring into existence, which a request budget alone only slows: at any rate a
//! real client could want, a loop over fresh UUIDs still fills the volume, and
//! every row it leaves behind carries its own assistant allowance and therefore
//! its own Bedrock spend.
//!
//! Top-level rather than inside a feature for the reason `identity` is: it sits
//! under all of them, and one of its two callers *is* `identity`.

use std::collections::hash_map::RandomState;
use std::hash::BuildHasher;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{Request, State};
use axum::http::HeaderMap;
use axum::middleware::Next;
use axum::response::Response;
use std::sync::Arc;
use tonic::Status;

use crate::state::AppState;

/// The header naming who is really calling.
///
/// Caddy *appends* the peer it accepted the connection from, so a caller who
/// sends a value of their own keeps it — as the left-most entry. Only the
/// right-most one was written by something we run, which is why [`client_key`]
/// reads from that end and no other.
pub const FORWARDED_FOR: &str = "x-forwarded-for";

/// How long a budget's allowance lasts before it refills.
const WINDOW: Duration = Duration::from_mins(1);

/// Requests per [`WINDOW`], per caller.
///
/// Deliberately far above what the app asks for and far below what a script
/// achieves. A launch is a handful of RPCs and an active minute is a few dozen,
/// so ten a second leaves roughly an order of magnitude of headroom for the one
/// case an IP-keyed budget has to survive: carrier-grade NAT, where a single
/// address fronts many people who have never met. A loop over fresh UUIDs runs
/// thousands a second, so the same number cuts the attack by three orders of
/// magnitude. It is set to bound the worst case, not to police the normal one.
pub const REQUESTS_PER_WINDOW: u32 = 600;

/// New `users` rows per [`WINDOW`], per caller.
///
/// Three orders of magnitude tighter than the request budget because the
/// behaviours are that far apart: a real client creates exactly one identity,
/// ever, and only an attacker creates a second one a second. Ten a minute
/// tolerates a NAT behind which several people install the app at once, and a
/// device reinstalling in a loop, while capping what a single address can add to
/// a 10 GiB volume at a rate a human would notice long before the disk did.
///
/// This is charged only when a row is genuinely created, so no established
/// client can ever be refused by it — see `identity::resolve`.
pub const NEW_IDENTITIES_PER_WINDOW: u32 = 10;

/// How many counters each budget keeps.
///
/// A fixed table rather than a map keyed by caller, because a map keyed by
/// whatever an attacker puts in a header is one more thing they can grow without
/// bound — the memory would become the attack the moment the rows stopped being
/// one. The cost is that two callers can share a counter; see [`Budget`].
const SLOTS: u64 = 4096;

/// How the two halves of a slot are packed. The spend occupies the low bits and
/// the window the high ones, so both move in one atomic write — kept apart, a
/// rollover could land between another request's read and write and reset a
/// counter that had just been spent.
const SPEND_BITS: u32 = 32;
const SPEND_MASK: u64 = (1 << SPEND_BITS) - 1;

/// A caller's allowance, counted in fixed windows over a fixed-size table.
///
/// Callers are hashed into [`SLOTS`] counters, so two of them can land on the
/// same one and share a budget. That is the price of bounded memory, and it is
/// paid in the right direction: a collision makes the limit stricter for two
/// callers, never absent for one. The hasher is `RandomState`, seeded per
/// process, so which callers collide is not something an attacker can work out
/// in advance and aim at somebody.
///
/// Fixed windows rather than a sliding log or a leaky bucket: a window admits up
/// to twice its limit across a boundary, which for an abuse control is noise,
/// and in exchange the whole thing is one atomic per request with nothing to
/// evict, no timer, and no allocation on the request path.
struct Budget {
    slots: Box<[AtomicU64]>,
    hasher: RandomState,
    limit: u64,
}

impl Budget {
    fn new(limit: u32) -> Self {
        Self {
            slots: (0..SLOTS).map(|_| AtomicU64::new(0)).collect(),
            hasher: RandomState::new(),
            limit: u64::from(limit),
        }
    }

    /// Charges one unit to `key`, reporting whether it was within budget.
    ///
    /// A refusal costs nothing further: the counter is never incremented past
    /// the limit, so a caller who keeps hammering cannot drive their own slot
    /// anywhere it was not already going.
    fn spend(&self, key: &str, now: Duration) -> bool {
        // Masked rather than merely divided, so the shift below cannot push
        // bits off the top. At a one-minute window the mask is reached after
        // about eight thousand years, and a caller alive on that boundary gets
        // one extra allowance.
        let window = (now.as_secs() / WINDOW.as_secs()) & SPEND_MASK;

        // `% SLOTS` in the u64 domain, so the index is provably below 4096 and
        // needs no fallible narrowing.
        let index = usize::try_from(self.hasher.hash_one(key) % SLOTS).unwrap_or(0);
        let slot = &self.slots[index];

        let mut packed = slot.load(Ordering::Relaxed);
        loop {
            let spent = if packed >> SPEND_BITS == window {
                packed & SPEND_MASK
            } else {
                0
            };

            if spent >= self.limit {
                return false;
            }

            let next = (window << SPEND_BITS) | (spent + 1);
            match slot.compare_exchange_weak(packed, next, Ordering::Relaxed, Ordering::Relaxed) {
                Ok(_) => return true,
                // Another request touched this slot first; re-read and retry
                // against what it left.
                Err(current) => packed = current,
            }
        }
    }
}

/// Both budgets, held for the life of the process.
///
/// Lives on `AppState` rather than being injected into it: it is not a seam —
/// nothing outside this crate chooses an implementation, and there is nothing
/// behind it to point somewhere harmless in a test. What a test wants is the
/// behaviour through the router, which `tests/e2e/throttle.rs` drives.
pub struct Throttle {
    requests: Budget,
    new_identities: Budget,
}

impl Throttle {
    pub fn new() -> Self {
        Self {
            requests: Budget::new(REQUESTS_PER_WINDOW),
            new_identities: Budget::new(NEW_IDENTITIES_PER_WINDOW),
        }
    }

    /// Whether `key` may make one more request this window.
    fn spend_request(&self, key: &str) -> bool {
        self.requests.spend(key, since_epoch())
    }

    /// Whether `key` may bring one more `users` row into existence this window.
    pub fn spend_new_identity(&self, key: &str) -> bool {
        self.new_identities.spend(key, since_epoch())
    }
}

/// The one answer a caller over either budget gets.
///
/// Shared by the two call sites so the client cannot learn which limit it met.
/// That is the useful property as well as the tidy one: telling somebody
/// probing for identities that they hit the *identity* budget tells them the
/// request budget is still open and worth switching to.
pub fn refused() -> Response {
    Status::resource_exhausted("rate limit exceeded").into_http()
}

impl Default for Throttle {
    fn default() -> Self {
        Self::new()
    }
}

/// A clock that cannot go backwards into a panic.
///
/// `SystemTime` before the epoch is not reachable on a machine that can reach
/// Postgres, and the alternative — an `Instant` baseline — would mean storing
/// one and subtracting on every request to compute the same number.
fn since_epoch() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
}

/// What to charge a request to.
///
/// The right-most `X-Forwarded-For` entry, which on this deployment is written
/// by Caddy and is therefore the peer it accepted — see [`FORWARDED_FOR`] for
/// why the other end of the list is worthless.
///
/// **The absent case is deliberately not an exemption.** No header means nothing
/// we run proxied this request, and on the box that cannot come from the
/// internet: `infra/main.tf` opens 443, 80 and SSH only, and `infra/box/
/// compose.yaml` publishes no host port for the api service, so Caddy is the
/// sole entrance. Such requests therefore share one budget rather than skipping
/// the check, so that the day something *is* exposed directly, the limit is
/// merely coarse instead of silently absent. It is also what the e2e suite and a
/// local `mise run dev` charge against, each against its own table.
pub fn client_key(headers: &HeaderMap) -> &str {
    const DIRECT: &str = "direct";

    headers
        .get(FORWARDED_FOR)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.rsplit(',').next())
        .map_or(DIRECT, str::trim)
}

/// Refuses a caller who has spent their request budget.
///
/// Inside `GrpcWebLayer` so the refusal leaves as a gRPC-Web status the client
/// can read, and outside `identity::resolve` so a refused request never reaches
/// the database at all — including the upsert that is the reason the second
/// budget exists.
pub async fn enforce(State(state): State<Arc<AppState>>, request: Request, next: Next) -> Response {
    if !state.throttle.spend_request(client_key(request.headers())) {
        // The key itself is not logged: it is somebody's IP address, and
        // `web/privacy.html` does not say this service keeps one. The request
        // span already carries the path, which is what makes the line useful.
        tracing::warn!("refused a request over its rate limit");
        return refused();
    }

    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers_with(forwarded_for: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(FORWARDED_FOR, forwarded_for.parse().expect("a valid value"));
        headers
    }

    /// The whole reason the right-hand end is read: a caller who forges the
    /// header keeps their forgery, and Caddy's entry lands after it. Reading
    /// from the left would let one attacker present a fresh identity per
    /// request and never meet either budget.
    #[test]
    fn a_forged_prefix_does_not_change_the_key() {
        assert_eq!(
            client_key(&headers_with("9.9.9.9, 203.0.113.7")),
            "203.0.113.7"
        );
        assert_eq!(client_key(&headers_with("203.0.113.7")), "203.0.113.7");
    }

    /// An unproxied request is charged, not waved through — see [`client_key`].
    #[test]
    fn a_request_with_no_forwarded_header_still_has_a_key() {
        assert!(!client_key(&HeaderMap::new()).is_empty());
    }

    #[test]
    fn a_budget_admits_its_limit_and_then_refuses() {
        let budget = Budget::new(3);
        let now = Duration::from_secs(0);

        assert!((0..3).all(|_| budget.spend("caller", now)));
        assert!(!budget.spend("caller", now));
    }

    /// Callers are counted apart, which is what makes the limit a limit on an
    /// attacker rather than on everybody at once.
    #[test]
    fn one_caller_exhausting_a_budget_leaves_another_untouched() {
        let budget = Budget::new(1);
        let now = Duration::from_secs(0);

        assert!(budget.spend("noisy", now));
        assert!(!budget.spend("noisy", now));
        assert!(budget.spend("quiet", now));
    }

    /// The allowance refills. Asserted by moving the clock rather than by
    /// sleeping, which is the only reason `spend` takes the time as an argument.
    #[test]
    fn a_new_window_refills_the_allowance() {
        let budget = Budget::new(1);

        assert!(budget.spend("caller", Duration::from_secs(0)));
        assert!(!budget.spend("caller", Duration::from_secs(59)));
        assert!(budget.spend("caller", WINDOW));
    }
}
