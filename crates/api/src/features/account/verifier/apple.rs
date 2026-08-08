//! Checking a Sign in with Apple identity token against Apple's published keys.
//!
//! ## What the check is
//!
//! An identity token is an ordinary JWT: three base64url segments, signed
//! RS256, whose header names the key by id rather than carrying it. So unlike
//! `entitlement::verifier::appstore` — which is handed the whole certificate
//! chain and can decide entirely in-process — the key has to be fetched from
//! Apple and kept. That fetch is the only reason this module has state.
//!
//! Five things must hold, and all five are here rather than split with the
//! caller: the algorithm is RS256; the signature verifies under the key the
//! header names; the issuer is Apple; the audience is this app; and the token
//! has not expired.
//!
//! ## Why the key set is cached the way it is
//!
//! Two rules, and each closes what the other opens. A cached set is dropped
//! after [`KEY_SET_TTL`] so a key Apple has withdrawn stops verifying tokens
//! within the hour. A `kid` the cache does not know forces a refetch, so a key
//! Apple has just rotated *in* works immediately rather than after that hour —
//! but no more often than [`MIN_REFETCH_INTERVAL`], because the `kid` is a value
//! the caller writes, and without the floor a stream of invented ids would be a
//! stream of requests to Apple with this server's name on them.
//!
//! ## What this deliberately does not read
//!
//! The `nonce` claim. Binding a token to a challenge this server issued would
//! stop one being replayed, and it buys nothing here: the token is already bound
//! to an audience and an expiry, and what a replay would achieve is signing in
//! as the person who owns the token — which requires their device to have
//! produced it in the first place. A nonce becomes worth it when a sign-in
//! grants something a replay could steal; today it grants access to the
//! attacker's own history.

use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::sync::RwLock;

use super::{IdentityTokenVerifier, VerificationError, VerifiedIdentity};
use crate::config::BUNDLE_ID;

/// Who Apple says it is, in every identity token it signs.
const ISSUER: &str = "https://appleid.apple.com";

/// Apple's JWKS endpoint. Public, unauthenticated, and the only network call
/// this feature makes.
const KEYS_URL: &str = "https://appleid.apple.com/auth/keys";

/// The only algorithm Apple signs identity tokens with.
///
/// Compared against the header rather than inferred from the key, which is what
/// closes the classic JWS confusion attacks: `none`, and anything that would
/// have the signature checked as a MAC keyed on a public value.
const SIGNING_ALGORITHM: &str = "RS256";

/// How long a fetched key set stays usable.
///
/// This is the window in which a key Apple has withdrawn still verifies tokens
/// here. An hour rather than a day because the cost of being wrong is accepting
/// a credential Apple has retired, and the cost of being right is one request an
/// hour to a public endpoint.
const KEY_SET_TTL: Duration = Duration::from_hours(1);

/// The floor between two fetches of the key set.
///
/// The `kid` is a field the caller writes, and an unknown one is what triggers a
/// refetch — so without this, invented key ids become outbound requests at
/// whatever rate they are sent. A minute keeps a genuine rotation nearly
/// immediate while making the amplification worthless.
const MIN_REFETCH_INTERVAL: Duration = Duration::from_mins(1);

/// The TTL has to be the longer of the two. If it were not, an expired set would
/// ask for a refresh that the floor then refused, and every sign-in would be
/// rejected as naming a key Apple does not have — which is a lie, and one no
/// test would think to look for.
const _: () = assert!(KEY_SET_TTL.as_secs() > MIN_REFETCH_INTERVAL.as_secs());

/// Bounds reaching Apple at all. A sign-in is a person waiting on a screen, so
/// the ceiling is what turns an unreachable endpoint into a message rather than
/// a spinner.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Bounds the whole key-set request. Generous against a slow network and short
/// enough to fail while the person is still looking at the screen.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// The verifier a deployment runs.
///
/// Holds a connection pool and the cached key set, which is what makes it a
/// struct where `AppStoreVerifier` is a unit — an App Store transaction carries
/// its own trust anchor, and this one has to go and get it.
pub struct AppleIdentityVerifier {
    http: reqwest::Client,
    keys: RwLock<KeySet>,
}

impl AppleIdentityVerifier {
    /// Builds a verifier around one long-lived connection pool and an empty
    /// cache.
    ///
    /// Fails only when the `reqwest::Client` cannot be built, which in practice
    /// means the TLS backend failed to initialise — a boot-time fault on a
    /// process whose database connection uses the same stack, so the caller has
    /// nothing to degrade to.
    ///
    /// The cache starts empty rather than warm: fetching at startup would put
    /// Apple's availability in front of this process's, for a key set the first
    /// sign-in fetches anyway.
    pub fn new() -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build()?;

        Ok(Self {
            http,
            keys: RwLock::new(KeySet::default()),
        })
    }

    /// The key `kid` names, fetching Apple's set if the cache cannot answer.
    async fn signing_key(&self, kid: &str) -> Result<SigningKey, VerificationError> {
        if let Some(key) = self.cached(kid).await {
            return Ok(key);
        }

        self.refresh().await?;

        self.cached(kid).await.ok_or_else(|| {
            VerificationError::Untrusted(format!("no Apple signing key is named `{kid}`"))
        })
    }

    /// The key from the cache, or `None` when the cache is empty, stale, or does
    /// not hold it.
    ///
    /// Cloned out rather than returned behind the guard: two hundred bytes per
    /// sign-in against a read lock that would otherwise be held across the
    /// signature check, which is the shape that turns a slow verify into a
    /// stalled refresh.
    async fn cached(&self, kid: &str) -> Option<SigningKey> {
        let cached = self.keys.read().await;

        if cached.fetched_at?.elapsed() >= KEY_SET_TTL {
            return None;
        }

        cached.keys.iter().find(|key| key.kid == kid).cloned()
    }

    /// Replaces the cached key set, unless somebody just did.
    ///
    /// The write lock is deliberately held across the request. It makes
    /// concurrent sign-ins share one fetch instead of each starting their own,
    /// and the recency check below is what makes the ones that queued behind it
    /// return without fetching again — so a burst of sign-ins after a rotation
    /// costs Apple one request rather than one each.
    // `significant_drop_tightening` reads the held guard as contention to
    // remove. Here it is the mechanism: releasing it before the fetch is exactly
    // what would let every queued caller start one of their own.
    #[allow(clippy::significant_drop_tightening)]
    async fn refresh(&self) -> Result<(), VerificationError> {
        let mut cached = self.keys.write().await;

        if cached
            .fetched_at
            .is_some_and(|at| at.elapsed() < MIN_REFETCH_INTERVAL)
        {
            return Ok(());
        }

        *cached = KeySet {
            keys: self.fetch().await?,
            fetched_at: Some(Instant::now()),
        };

        Ok(())
    }

    /// Reads Apple's JWKS, keeping the keys this server can actually use.
    ///
    /// Apple's set has carried only RS256 keys for years, and the filter is
    /// still here because a key of some other type arriving is an addition to
    /// their set rather than a failure of ours — dropping it is right, and
    /// refusing every sign-in over it would not be.
    async fn fetch(&self) -> Result<Vec<SigningKey>, VerificationError> {
        let response = self
            .http
            .get(KEYS_URL)
            .send()
            .await
            .map_err(|error| VerificationError::Unavailable(error.to_string()))?
            .error_for_status()
            .map_err(|error| VerificationError::Unavailable(error.to_string()))?;

        let key_set: JsonWebKeySet = response
            .json()
            .await
            .map_err(|error| VerificationError::Unavailable(error.to_string()))?;

        let keys: Vec<SigningKey> = key_set
            .keys
            .iter()
            .filter_map(SigningKey::from_jwk)
            .collect();

        if keys.is_empty() {
            return Err(VerificationError::Unavailable(
                "Apple's key set carries no usable RS256 key".to_owned(),
            ));
        }

        Ok(keys)
    }
}

#[tonic::async_trait]
impl IdentityTokenVerifier for AppleIdentityVerifier {
    async fn verify(&self, identity_token: &str) -> Result<VerifiedIdentity, VerificationError> {
        let (signing_input, header, payload, signature) = split(identity_token)?;

        let header: JwtHeader = decode_json(&header, "header")?;
        if header.alg != SIGNING_ALGORITHM {
            return Err(VerificationError::Untrusted(format!(
                "`alg` is `{}`, not {SIGNING_ALGORITHM}",
                header.alg
            )));
        }

        let key = self.signing_key(&header.kid).await?;
        verify_signature(&key, signing_input, &signature)?;

        // Only now: everything below is a claim the token makes about itself,
        // and until the signature holds, none of it is Apple's claim.
        let claims: Claims = decode_json(&payload, "payload")?;
        claims.into_verified(Utc::now())
    }
}

/// Apple's key set, and when it was read.
///
/// `fetched_at` is `None` for the set no request has filled yet, which is what
/// [`AppleIdentityVerifier::cached`] reads as "cannot answer" without a separate
/// emptiness check.
#[derive(Default)]
struct KeySet {
    keys: Vec<SigningKey>,
    fetched_at: Option<Instant>,
}

/// One RSA public key from Apple's set, decoded ready for `ring`.
#[derive(Clone)]
struct SigningKey {
    kid: String,
    /// The modulus and exponent as big-endian bytes, which is the form
    /// `RsaPublicKeyComponents` takes.
    modulus: Vec<u8>,
    exponent: Vec<u8>,
}

impl SigningKey {
    /// `None` for a key this server cannot verify with, which the caller drops
    /// rather than failing over.
    fn from_jwk(jwk: &JsonWebKey) -> Option<Self> {
        if jwk.kty != "RSA" || jwk.alg.as_deref() != Some(SIGNING_ALGORITHM) {
            return None;
        }

        Some(Self {
            kid: jwk.kid.clone(),
            modulus: URL_SAFE_NO_PAD.decode(&jwk.n).ok()?,
            exponent: URL_SAFE_NO_PAD.decode(&jwk.e).ok()?,
        })
    }
}

/// A JWKS as Apple serves it. Only the keys array is read; the response carries
/// nothing else.
#[derive(Deserialize)]
struct JsonWebKeySet {
    keys: Vec<JsonWebKey>,
}

/// One entry of that set. `alg` is optional in RFC 7517 and always present in
/// Apple's, so an entry without it is one this server declines to guess about.
#[derive(Deserialize)]
struct JsonWebKey {
    kid: String,
    kty: String,
    alg: Option<String>,
    n: String,
    e: String,
}

/// The JWT header, of which only two fields matter.
#[derive(Deserialize)]
struct JwtHeader {
    alg: String,

    /// Which of Apple's keys signed this. Apple publishes several at once and
    /// rotates them, so the token names one rather than carrying it.
    kid: String,
}

/// The subset of Apple's identity-token claims anything here acts on.
///
/// Four of about ten. `email`, `email_verified`, `is_private_email`,
/// `auth_time`, `nonce_supported` and the rest are each a field to keep in step
/// with a schema Apple owns, in exchange for nothing that decides a binding.
#[derive(Deserialize)]
struct Claims {
    iss: String,

    /// The bundle id of the app the sign-in was performed in. A single string
    /// for a native app; a token carrying an array is not one this server issued
    /// a sign-in for, and fails to deserialize rather than being searched.
    aud: String,

    /// The stable per-team identifier for this Apple account — what gets written
    /// to `users.apple_user_id`.
    sub: String,

    /// Epoch seconds.
    exp: i64,
}

impl Claims {
    /// The three checks that are about identity and freshness rather than
    /// signature: a perfectly genuine Apple token issued for another app, from
    /// another issuer, or expired, binds nobody here.
    ///
    /// `now` is a parameter so the expiry rule is testable without waiting for
    /// one.
    fn into_verified(self, now: DateTime<Utc>) -> Result<VerifiedIdentity, VerificationError> {
        if self.iss != ISSUER {
            return Err(VerificationError::Untrusted(format!(
                "`iss` is `{}`, not `{ISSUER}`",
                self.iss
            )));
        }

        if self.aud != BUNDLE_ID {
            return Err(VerificationError::NotOurs(format!(
                "`aud` is `{}`, not `{BUNDLE_ID}`",
                self.aud
            )));
        }

        let expires_at = DateTime::from_timestamp(self.exp, 0).ok_or_else(|| {
            VerificationError::Malformed("`exp` is not a representable time".to_owned())
        })?;

        if expires_at <= now {
            return Err(VerificationError::Untrusted(format!(
                "the token expired at {expires_at}"
            )));
        }

        if self.sub.is_empty() {
            return Err(VerificationError::Malformed(
                "`sub` is empty, so the token names no Apple account".to_owned(),
            ));
        }

        Ok(VerifiedIdentity {
            apple_user_id: self.sub,
        })
    }
}

/// Checks the RS256 signature over the signing input.
///
/// A free function rather than a method so the wiring to `ring` is exercised by
/// a unit test: everything above it needs a key from Apple, and this does not.
fn verify_signature(
    key: &SigningKey,
    signing_input: &[u8],
    signature: &[u8],
) -> Result<(), VerificationError> {
    ring::signature::RsaPublicKeyComponents {
        n: &key.modulus,
        e: &key.exponent,
    }
    .verify(
        &ring::signature::RSA_PKCS1_2048_8192_SHA256,
        signing_input,
        signature,
    )
    .map_err(|_| {
        VerificationError::Untrusted(format!(
            "the signature does not verify under Apple's key `{}`",
            key.kid
        ))
    })
}

/// The signing input, the two decoded JSON segments, and the raw signature.
///
/// The signing input is the first two segments and the dot between them,
/// verbatim — re-encoding the decoded parts would produce different bytes and a
/// signature that never verifies.
type Segments<'a> = (&'a [u8], Vec<u8>, Vec<u8>, Vec<u8>);

fn split(identity_token: &str) -> Result<Segments<'_>, VerificationError> {
    let mut parts = identity_token.split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(VerificationError::Malformed(
            "a JWT is exactly three dot-separated segments".to_owned(),
        ));
    };

    let signing_input_len = header.len() + 1 + payload.len();

    Ok((
        &identity_token.as_bytes()[..signing_input_len],
        decode_segment(header, "header")?,
        decode_segment(payload, "payload")?,
        decode_segment(signature, "signature")?,
    ))
}

fn decode_segment(segment: &str, name: &str) -> Result<Vec<u8>, VerificationError> {
    URL_SAFE_NO_PAD.decode(segment).map_err(|error| {
        VerificationError::Malformed(format!("the {name} is not base64url: {error}"))
    })
}

fn decode_json<T: for<'de> Deserialize<'de>>(
    segment: &[u8],
    name: &str,
) -> Result<T, VerificationError> {
    serde_json::from_slice(segment).map_err(|error| {
        VerificationError::Malformed(format!(
            "the {name} is not the JSON an identity token carries: {error}"
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A claim set this server would honour, for the tests that change one field
    /// and assert it no longer would.
    fn claims() -> Claims {
        Claims {
            iss: ISSUER.to_owned(),
            aud: BUNDLE_ID.to_owned(),
            sub: "001234.abcdef0123456789abcdef0123456789.0123".to_owned(),
            exp: 1_800_000_000,
        }
    }

    fn instant(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("a valid instant")
    }

    /// Three segments, and only three. A token missing its signature must fail
    /// as malformed rather than reaching a path that treats an absent signature
    /// as an empty one.
    #[test]
    fn a_token_that_is_not_a_jwt_is_malformed() {
        for token in ["", "not-a-jwt", "one.two", "one.two.three.four"] {
            let error = split(token).expect_err("a token of the wrong shape is not a JWT");

            assert!(matches!(error, VerificationError::Malformed(_)), "{token}");
        }
    }

    /// The signature is checked against the key Apple named, and a signature
    /// that is not one must not pass. Everything above this function needs a key
    /// fetched from Apple; this is the part that can be pinned offline, and
    /// without it deleting the `verify_signature` call would leave the rest of
    /// this file's tests passing.
    #[test]
    fn a_signature_that_is_not_the_keys_does_not_verify() {
        let key = SigningKey {
            kid: "test".to_owned(),
            // A 2048-bit modulus of the right shape and nobody's in particular,
            // with the exponent every RSA JWK carries.
            modulus: vec![0xFF; 256],
            exponent: vec![0x01, 0x00, 0x01],
        };

        let error = verify_signature(&key, b"signing-input", &[0_u8; 256])
            .expect_err("zeroes are not a signature");

        assert!(matches!(error, VerificationError::Untrusted(_)), "{error}");
    }

    /// The audience check is what stops a genuine Apple token issued for another
    /// app from binding anything here — the same rule, and the same reason, as
    /// the bundle id on an App Store transaction.
    #[test]
    fn a_token_for_another_app_is_not_ours() {
        let error = Claims {
            aud: "com.example.other".to_owned(),
            ..claims()
        }
        .into_verified(instant(1_700_000_000))
        .expect_err("another app's audience binds nobody here");

        assert!(matches!(error, VerificationError::NotOurs(_)), "{error}");
    }

    /// `iss` is compared rather than assumed. A token from any other issuer is
    /// one somebody else can mint, and the whole of this feature's trust is that
    /// they cannot.
    #[test]
    fn a_token_from_another_issuer_is_untrusted() {
        let error = Claims {
            iss: "https://accounts.example.com".to_owned(),
            ..claims()
        }
        .into_verified(instant(1_700_000_000))
        .expect_err("only Apple issues these");

        assert!(matches!(error, VerificationError::Untrusted(_)), "{error}");
    }

    /// Apple's identity tokens are short-lived on purpose, and the expiry is the
    /// only thing that makes a captured one stop working. Asserted on both sides
    /// of the boundary, because a comparison written the wrong way round passes
    /// every test that only checks the valid case.
    #[test]
    fn an_expired_token_binds_nobody() {
        let expiry = claims().exp;

        assert!(claims().into_verified(instant(expiry - 1)).is_ok());

        for at in [expiry, expiry + 1] {
            let error = claims()
                .into_verified(instant(at))
                .expect_err("a token past its expiry is spent");

            assert!(matches!(error, VerificationError::Untrusted(_)), "{at}");
        }
    }

    /// `sub` is the key a person's whole history is filed under, so an empty one
    /// must not become a row that every future empty `sub` then matches.
    #[test]
    fn a_token_naming_no_account_is_malformed() {
        let error = Claims {
            sub: String::new(),
            ..claims()
        }
        .into_verified(instant(1_700_000_000))
        .expect_err("an empty subject names nobody");

        assert!(matches!(error, VerificationError::Malformed(_)), "{error}");
    }

    /// Only RS256 RSA keys are kept, and both halves are decoded from base64url
    /// — a key whose components did not decode would otherwise reach `ring` as
    /// an empty modulus.
    #[test]
    fn only_usable_keys_survive_the_key_set() {
        let jwk = |kty: &str, alg: Option<&str>, n: &str| JsonWebKey {
            kid: "W6WcOKB".to_owned(),
            kty: kty.to_owned(),
            alg: alg.map(ToOwned::to_owned),
            n: n.to_owned(),
            e: "AQAB".to_owned(),
        };

        assert!(SigningKey::from_jwk(&jwk("RSA", Some("RS256"), "AQAB")).is_some());
        assert!(SigningKey::from_jwk(&jwk("EC", Some("RS256"), "AQAB")).is_none());
        assert!(SigningKey::from_jwk(&jwk("RSA", Some("RS512"), "AQAB")).is_none());
        assert!(SigningKey::from_jwk(&jwk("RSA", None, "AQAB")).is_none());
        assert!(
            SigningKey::from_jwk(&jwk("RSA", Some("RS256"), "not base64url!")).is_none(),
            "a component that does not decode is not a key"
        );
    }
}
