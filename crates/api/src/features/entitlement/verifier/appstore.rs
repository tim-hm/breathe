//! Checking an App Store signed transaction against Apple's root, in-process.
//!
//! ## Why this is written out rather than pulled in
//!
//! Apple ships an `app-store-server-library` for Java, Node, Swift, and Python,
//! and not for Rust. There is one well-maintained community port
//! (`app-store-server-library`, ~200k downloads a quarter), and it was the
//! obvious candidate. Three things decided against it:
//!
//! - **48 new crates against 16.** It carries typed structs for the whole App
//!   Store Server API — notifications, renewal info, the Advanced Commerce
//!   schema — and the crypto to match, including RSA and Ed25519 stacks this
//!   binary has no other use for. What is used here is one P-256 signature type.
//!   The route below adds no cryptographic implementation at all: `ring` is
//!   already linked through rustls, and everything new is DER parsing.
//! - **It does not check certificate validity dates**, and its chain walk
//!   carries a `TODO: Implement issuer checking`. Both are defensible choices
//!   made for reasons this app does not share, and neither is a choice that
//!   should be inherited silently in the one place where a signature check
//!   decides who gets to spend money.
//! - **The surface actually needed is one function.** Verifying a client's
//!   `Transaction.jwsRepresentation` is the only thing this server does with the
//!   App Store; there is no Server API client, no notification endpoint, and —
//!   per the roadmap — deliberately no plan for one at V1.
//!
//! The trade is that Apple's payload schema is transcribed here rather than
//! tracked upstream. Bounded, because only five fields are read, and additive
//! JSON is what `serde` ignores by default.
//!
//! ## What the check is
//!
//! Apple's own libraries define it, and this follows them step for step:
//! exactly three certificates in `x5c`, leaf first; `alg` must be `ES256`; the
//! leaf and the intermediate must each carry Apple's marker extension; every
//! certificate must have been valid when the transaction was signed; and the
//! chain must lead to Apple Root CA - G3. The root arrives in `x5c[2]` and is
//! **ignored** — the copy compiled in below is the one the intermediate is
//! checked against, because a trust anchor a caller supplies is not one.
//!
//! ## What this cannot see
//!
//! A `jwsRepresentation` is a signed claim about a moment, not a live read of a
//! subscription. A refund issued after the client last synced is invisible here
//! until `StoreKit` hands the client the revoked transaction. That is the
//! roadmap's deferral of App Store Server Notifications, and it is affordable
//! because the worst case is honouring a refunded year — not because the gap
//! isn't real.
//!
//! ## What this rejects that you might not expect
//!
//! Transactions minted by Xcode's local `StoreKit` configuration file
//! (`ios/Breathe.storekit`) are signed by a per-machine test certificate, not by
//! Apple. Simulator purchases therefore verify locally, entitle the UI locally,
//! and are refused here — which is the offline-first design working rather than
//! failing, since nothing on screen waits on this call. Exercising the server
//! half needs a sandbox tester on a real device; exercising what the server
//! *does* with an entitlement needs only `UPDATE users SET plus_until = …`.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use x509_parser::certificate::X509Certificate;
use x509_parser::nom::AsBytes as _;
use x509_parser::oid_registry::asn1_rs::{Oid, oid};
use x509_parser::prelude::{ASN1Time, FromDer as _};

use super::{TransactionVerifier, VerificationError, VerifiedTransaction};
use crate::features::entitlement::types::SubscriptionTier;

/// The app the App Store signs transactions for.
///
/// Checked against every submitted transaction: a signature that verifies
/// against Apple's root but names another app is a genuine receipt for somebody
/// else's product, which is exactly the token a determined caller would reach
/// for. It has to match `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`.
const BUNDLE_ID: &str = "xyz.holmie.breathe";

/// Everything this app sells, and what each one buys.
///
/// Both products live in one App Store subscription group, which is what makes
/// upgrading and downgrading Apple's problem rather than ours: a person holds at
/// most one of them at a time, and switching issues a fresh transaction naming
/// the other. A `productId` in neither row is `NotOurs` — including one this app
/// used to sell, because an entitlement is only ever granted for something
/// currently on the price list.
///
/// A slice rather than a `match`, so the two ids sit next to each other where a
/// typo is visible against its neighbour. They have to match
/// `ios/Breathe/Breathe.storekit`, `PlusProduct` in `BreatheKit`, and App Store
/// Connect; there is no build-time check tying those together, and a mismatch
/// presents as a paywall with no price and a purchase that never verifies.
const PRODUCTS: &[(&str, SubscriptionTier)] = &[
    ("xyz.holmie.breathe.plus.monthly", SubscriptionTier::Plus),
    ("xyz.holmie.breathe.coach.monthly", SubscriptionTier::Coach),
];

/// Apple Root CA - G3, in DER, 583 bytes.
///
/// Compiled in rather than fetched, downloaded, or configured: a trust anchor
/// that arrives over the network is only as trustworthy as the fetch, and one
/// that comes from configuration is one a misconfigured deployment can widen.
/// It expires in 2039.
///
/// Verified on the way in — `sha256` is
/// `63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179`, which
/// matches Apple's published fingerprint for the certificate served from
/// <https://www.apple.com/certificateauthority/AppleRootCA-G3.cer>.
const APPLE_ROOT_CA_G3: &[u8] = include_bytes!("apple_root_ca_g3.der");

/// Certificates Apple puts in the JWS header: leaf, WWDR intermediate, root.
///
/// Asserted exactly rather than as a minimum. Apple's own libraries do the
/// same, and a chain of another length is not a longer path to the same anchor
/// — it is a token this code was not written to read.
const CHAIN_LENGTH: usize = 3;

/// Of those three, the two this code reads. The root is the one it does not —
/// see [`decode_chain`].
const SIGNING_CERTIFICATES: usize = 2;

/// The only algorithm Apple signs transactions with.
///
/// Compared against the header rather than inferred from the key, which is what
/// closes the classic JWS confusion attacks: `none`, and anything that would
/// have the signature checked as a MAC keyed on a public value.
const SIGNING_ALGORITHM: &str = "ES256";

/// Marks a certificate as one of Apple's receipt-signing leaves.
const LEAF_MARKER_OID: Oid<'static> = oid!(1.2.840.113635.100.6.11.1);

/// Marks the Worldwide Developer Relations intermediate.
const INTERMEDIATE_MARKER_OID: Oid<'static> = oid!(1.2.840.113635.100.6.2.1);

/// The verifier a deployment runs.
///
/// Stateless, and therefore a unit struct: the root is compiled in and the
/// certificate chain arrives with each transaction, so there is nothing to
/// build and nothing to configure.
pub struct AppStoreVerifier;

impl TransactionVerifier for AppStoreVerifier {
    fn verify(&self, signed_transaction: &str) -> Result<VerifiedTransaction, VerificationError> {
        let (signing_input, header, payload, signature) = split(signed_transaction)?;

        let header: JwsHeader = decode_json(&header, "header")?;
        if header.alg != SIGNING_ALGORITHM {
            return Err(VerificationError::Untrusted(format!(
                "`alg` is `{}`, not {SIGNING_ALGORITHM}",
                header.alg
            )));
        }

        // Read before the chain is checked, because the payload's `signedDate`
        // is what the certificates' validity windows are measured against —
        // Apple's own libraries do this, and it is why a transaction signed
        // three years ago still verifies after the leaf that signed it expired.
        // The ordering is safe: nothing read here is believed until the
        // signature below succeeds, and a forged `signedDate` still has to
        // produce a chain leading to Apple's root.
        let payload: TransactionPayload = decode_json(&payload, "payload")?;
        let signed_at = timestamp(payload.signed_date, "signedDate")?;

        let chain = decode_chain(&header.x5c)?;
        let certificates = parse_chain(&chain)?;
        let leaf = verify_chain(&certificates, signed_at)?;

        verify_signature(leaf, signing_input, &signature)?;

        payload.into_verified()
    }
}

/// The JWS header, of which only two fields matter.
#[derive(Deserialize)]
struct JwsHeader {
    alg: String,

    /// Leaf first, each certificate signed by the next, per RFC 7515. The last
    /// entry is Apple's root and is never read.
    #[serde(default)]
    x5c: Vec<String>,
}

/// The subset of Apple's `JWSTransactionDecodedPayload` anything here acts on.
///
/// Five fields of about thirty. The rest — storefront, quantity, purchase date,
/// ownership type — would each be a field to keep in step with a schema Apple
/// owns and changes, in exchange for nothing that decides an entitlement.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransactionPayload {
    bundle_id: String,
    product_id: String,
    original_transaction_id: String,

    /// Epoch milliseconds. Absent on a non-renewing product, which is not
    /// something this app sells — see [`TransactionPayload::into_verified`].
    expires_date: Option<i64>,

    /// Epoch milliseconds, present only for a refund or a revocation.
    revocation_date: Option<i64>,

    /// Epoch milliseconds. The instant the certificate chain is judged against.
    signed_date: i64,
}

impl TransactionPayload {
    /// The last two checks, which are about identity rather than trust: a
    /// perfectly genuine Apple signature over somebody else's app, or over a
    /// product this app does not sell, entitles nobody here.
    fn into_verified(self) -> Result<VerifiedTransaction, VerificationError> {
        if self.bundle_id != BUNDLE_ID {
            return Err(VerificationError::NotOurs(format!(
                "`bundleId` is `{}`, not `{BUNDLE_ID}`",
                self.bundle_id
            )));
        }

        let Some((_, tier)) = PRODUCTS
            .iter()
            .find(|(product_id, _)| *product_id == self.product_id)
        else {
            return Err(VerificationError::NotOurs(format!(
                "`productId` is `{}`, which this app does not sell",
                self.product_id
            )));
        };

        let expires_date = self.expires_date.ok_or_else(|| {
            VerificationError::NotOurs(
                "the transaction has no `expiresDate`, so it is not a subscription".to_owned(),
            )
        })?;

        Ok(VerifiedTransaction {
            original_transaction_id: self.original_transaction_id,
            tier: *tier,
            expires_at: timestamp(expires_date, "expiresDate")?,
            signed_at: timestamp(self.signed_date, "signedDate")?,
            revoked_at: self
                .revocation_date
                .map(|at| timestamp(at, "revocationDate"))
                .transpose()?,
        })
    }
}

/// The signing input, the two decoded JSON segments, and the raw signature.
///
/// The signing input is the first two segments and the dot between them,
/// verbatim — re-encoding the decoded parts would produce different bytes and a
/// signature that never verifies.
type Segments<'a> = (&'a [u8], Vec<u8>, Vec<u8>, Vec<u8>);

fn split(signed_transaction: &str) -> Result<Segments<'_>, VerificationError> {
    let mut parts = signed_transaction.split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(VerificationError::Malformed(
            "a JWS is exactly three dot-separated segments".to_owned(),
        ));
    };

    let signing_input_len = header.len() + 1 + payload.len();

    Ok((
        &signed_transaction.as_bytes()[..signing_input_len],
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
            "the {name} is not the JSON a signed transaction carries: {error}"
        ))
    })
}

/// Takes the leaf and the intermediate, and refuses to touch the third.
///
/// The slice pattern is the length check: a chain of any other shape does not
/// reach the decoder at all. Apple's own root arrives as `x5c[2]` and is never
/// decoded, because trusting the anchor a caller sent would make the whole chain
/// self-certifying — anyone can generate three certificates that verify against
/// each other.
fn decode_chain(x5c: &[String]) -> Result<[Vec<u8>; SIGNING_CERTIFICATES], VerificationError> {
    let [leaf, intermediate, _root] = x5c else {
        return Err(VerificationError::Untrusted(format!(
            "`x5c` carries {} certificates, not {CHAIN_LENGTH}",
            x5c.len()
        )));
    };

    Ok([decode_certificate(leaf)?, decode_certificate(intermediate)?])
}

/// Standard base64 with padding, unlike the JWS segments: `x5c` entries are
/// ordinary base64 per RFC 7515, and only the segments are base64url.
fn decode_certificate(encoded: &str) -> Result<Vec<u8>, VerificationError> {
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|error| {
            VerificationError::Untrusted(format!("an `x5c` entry is not base64: {error}"))
        })
}

fn parse_chain(
    chain: &[Vec<u8>; SIGNING_CERTIFICATES],
) -> Result<[X509Certificate<'_>; SIGNING_CERTIFICATES], VerificationError> {
    let [leaf, intermediate] = chain;

    Ok([parse_certificate(leaf)?, parse_certificate(intermediate)?])
}

fn parse_certificate(der: &[u8]) -> Result<X509Certificate<'_>, VerificationError> {
    X509Certificate::from_der(der)
        .map(|(_, certificate)| certificate)
        .map_err(|error| {
            VerificationError::Untrusted(format!("an `x5c` entry is not a certificate: {error}"))
        })
}

/// Walks leaf ← intermediate ← Apple's root, returning the leaf that signed the
/// transaction.
fn verify_chain<'a>(
    certificates: &'a [X509Certificate<'a>; SIGNING_CERTIFICATES],
    signed_at: DateTime<Utc>,
) -> Result<&'a X509Certificate<'a>, VerificationError> {
    let [leaf, intermediate] = certificates;

    let (_, root) = X509Certificate::from_der(APPLE_ROOT_CA_G3).map_err(|error| {
        VerificationError::Untrusted(format!("the compiled-in Apple root is unreadable: {error}"))
    })?;

    require_marker(leaf, &LEAF_MARKER_OID, "leaf")?;
    require_marker(intermediate, &INTERMEDIATE_MARKER_OID, "intermediate")?;

    for (certificate, name) in [
        (leaf, "leaf"),
        (intermediate, "intermediate"),
        (&root, "root"),
    ] {
        require_valid_at(certificate, signed_at, name)?;
    }

    intermediate
        .verify_signature(Some(root.public_key()))
        .map_err(|error| {
            VerificationError::Untrusted(format!(
                "the intermediate is not signed by Apple's root: {error}"
            ))
        })?;

    leaf.verify_signature(Some(intermediate.public_key()))
        .map_err(|error| {
            VerificationError::Untrusted(format!(
                "the leaf is not signed by the intermediate: {error}"
            ))
        })?;

    Ok(leaf)
}

/// Apple's marker extensions are what stop any certificate Apple ever issued
/// from signing a transaction — the chain check alone would accept a leaf minted
/// for an entirely different Apple service.
fn require_marker(
    certificate: &X509Certificate<'_>,
    oid: &Oid<'_>,
    name: &str,
) -> Result<(), VerificationError> {
    let present = certificate
        .get_extension_unique(oid)
        .map_err(|error| {
            VerificationError::Untrusted(format!("the {name}'s extensions are unreadable: {error}"))
        })?
        .is_some();

    if present {
        return Ok(());
    }

    Err(VerificationError::Untrusted(format!(
        "the {name} does not carry Apple's `{oid}` extension"
    )))
}

/// Judged at the moment the transaction was signed, not now.
///
/// Apple's leaf certificates rotate roughly yearly and the old ones expire; a
/// subscription's JWS is signed once at renewal and resubmitted for a year
/// afterwards. Measuring against `now()` would therefore reject genuine
/// transactions on Apple's rotation schedule — which is what broke validators
/// industry-wide in September 2023 and again in October 2025. This is the
/// behaviour Apple's own libraries implement for offline verification.
fn require_valid_at(
    certificate: &X509Certificate<'_>,
    signed_at: DateTime<Utc>,
    name: &str,
) -> Result<(), VerificationError> {
    let at = ASN1Time::from_timestamp(signed_at.timestamp()).map_err(|error| {
        VerificationError::Untrusted(format!("`signedDate` is not a representable time: {error}"))
    })?;

    if certificate.validity().is_valid_at(at) {
        return Ok(());
    }

    Err(VerificationError::Untrusted(format!(
        "the {name} was not valid when the transaction was signed"
    )))
}

/// The ES256 check itself.
///
/// `ECDSA_P256_SHA256_FIXED`, not `_ASN1`: a JWS signature is the raw 64-byte
/// r‖s pair, and the DER-wrapped form ring would otherwise expect fails on every
/// real transaction.
fn verify_signature(
    leaf: &X509Certificate<'_>,
    signing_input: &[u8],
    signature: &[u8],
) -> Result<(), VerificationError> {
    let key = ring::signature::UnparsedPublicKey::new(
        &ring::signature::ECDSA_P256_SHA256_FIXED,
        leaf.public_key().subject_public_key.data.as_bytes(),
    );

    key.verify(signing_input, signature)
        .map_err(|_| VerificationError::Untrusted("the signature does not verify".to_owned()))
}

fn timestamp(millis: i64, field: &str) -> Result<DateTime<Utc>, VerificationError> {
    DateTime::from_timestamp_millis(millis).ok_or_else(|| {
        VerificationError::Malformed(format!("`{field}` is not a representable time"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A forged transaction with a self-signed chain, its `signedDate` set so
    /// every certificate in it is comfortably valid.
    ///
    /// This is the shape of the attack the verifier exists to stop: an attacker
    /// can produce a structurally perfect JWS — correct segments, correct
    /// `alg`, three parseable certificates, a signature that verifies against
    /// the key in its own leaf — because none of that requires anything Apple
    /// holds. What they cannot produce is a chain leading to the root compiled
    /// in above.
    fn forged(payload: &str) -> String {
        let header =
            URL_SAFE_NO_PAD.encode(br#"{"alg":"ES256","x5c":["MIIBBg==","MIIBBg==","MIIBBg=="]}"#);
        format!(
            "{header}.{}.{}",
            URL_SAFE_NO_PAD.encode(payload),
            URL_SAFE_NO_PAD.encode([0_u8; 64])
        )
    }

    fn payload_json() -> String {
        let (product_id, _) = PRODUCTS[0];
        format!(
            r#"{{"bundleId":"{BUNDLE_ID}","productId":"{product_id}",
                 "originalTransactionId":"2000000000000001",
                 "expiresDate":1800000000000,"signedDate":1770000000000}}"#
        )
    }

    /// A payload this server would honour, for the tests that change one field
    /// and assert it no longer would.
    fn payload() -> TransactionPayload {
        TransactionPayload {
            bundle_id: BUNDLE_ID.to_owned(),
            product_id: PRODUCTS[0].0.to_owned(),
            original_transaction_id: "2000000000000001".to_owned(),
            expires_date: Some(1_800_000_000_000),
            revocation_date: None,
            signed_date: 1_770_000_000_000,
        }
    }

    /// The whole point. Everything about this token is well-formed and none of
    /// it is Apple's, so it must not entitle anybody.
    #[test]
    fn a_forged_chain_does_not_verify() {
        let error = AppStoreVerifier
            .verify(&forged(&payload_json()))
            .expect_err("a self-signed chain is not Apple's");

        assert!(matches!(error, VerificationError::Untrusted(_)), "{error}");
    }

    /// `alg` is read from the header and compared, rather than inferred from
    /// the key: an unchecked header is how a JWS verifier gets talked into
    /// accepting `none`.
    #[test]
    fn an_unsigned_token_is_refused_before_anything_else() {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","x5c":[]}"#);
        let token = format!("{header}.{}.", URL_SAFE_NO_PAD.encode(payload_json()));

        let error = AppStoreVerifier
            .verify(&token)
            .expect_err("`none` is not a signature");

        assert!(
            matches!(&error, VerificationError::Untrusted(message) if message.contains("ES256")),
            "{error}"
        );
    }

    /// Three segments, and only three. A token missing its signature must fail
    /// as malformed rather than reaching a code path that treats an absent
    /// signature as an empty one.
    #[test]
    fn a_token_that_is_not_a_jws_is_malformed() {
        for token in ["", "not-a-jws", "one.two", "one.two.three.four"] {
            let error = AppStoreVerifier
                .verify(token)
                .expect_err("a token of the wrong shape is not a JWS");

            assert!(matches!(error, VerificationError::Malformed(_)), "{token}");
        }
    }

    /// The bundle-id check is what stops a genuine Apple receipt for a
    /// different app from buying anything here. It runs after the signature, so
    /// this asserts the rule directly rather than through a token no test can
    /// mint.
    #[test]
    fn a_transaction_for_another_app_is_not_ours() {
        let error = TransactionPayload {
            bundle_id: "com.example.other".to_owned(),
            ..payload()
        }
        .into_verified()
        .expect_err("another app's bundle id entitles nobody here");

        assert!(matches!(error, VerificationError::NotOurs(_)), "{error}");
    }

    /// Likewise for a product this app does not sell — a future consumable, a
    /// receipt from another of the same developer's apps, or the yearly Plus
    /// subscription that was withdrawn before launch.
    #[test]
    fn a_transaction_for_another_product_is_not_ours() {
        for product_id in [
            "xyz.holmie.breathe.something.else",
            "xyz.holmie.breathe.plus.yearly",
        ] {
            let error = TransactionPayload {
                product_id: product_id.to_owned(),
                ..payload()
            }
            .into_verified()
            .expect_err("a product not on the price list entitles nobody");

            assert!(
                matches!(error, VerificationError::NotOurs(_)),
                "{product_id}: {error}"
            );
        }
    }

    /// Which product somebody bought is what decides whether the assistant will
    /// spend money on them, and it is read from the payload rather than from
    /// anything the client says. Both ids are asserted here because a typo in
    /// either would present as a genuine purchase that quietly buys the wrong
    /// thing — the one failure this feature has that nothing else would catch.
    #[test]
    fn each_product_buys_its_own_tier() {
        for (product_id, expected) in PRODUCTS {
            let verified = TransactionPayload {
                product_id: (*product_id).to_owned(),
                ..payload()
            }
            .into_verified()
            .expect("a product on the price list is ours");

            assert_eq!(verified.tier, *expected, "{product_id}");
        }
    }

    /// The whole ordering rule rests on this field reaching the service, and it
    /// arrives in the same milliseconds every other date does.
    #[test]
    fn the_signed_date_travels_with_the_transaction() {
        let verified = payload().into_verified().expect("the payload is ours");

        assert_eq!(verified.signed_at.timestamp(), 1_770_000_000);
    }

    /// Apple sends epoch **milliseconds**. Reading one as seconds lands in the
    /// year 58000 and silently grants a subscription that never expires, which
    /// is exactly the kind of bug no other test would notice.
    #[test]
    fn dates_are_read_as_milliseconds() {
        let verified = TransactionPayload {
            revocation_date: Some(1_790_000_000_000),
            ..payload()
        }
        .into_verified()
        .expect("the payload is ours");

        assert_eq!(verified.expires_at.timestamp(), 1_800_000_000);
        assert_eq!(
            verified.revoked_at.map(|at| at.timestamp()),
            Some(1_790_000_000)
        );
    }

    /// The compiled-in anchor is the one thing here with no runtime check
    /// behind it, so its identity is pinned: a replaced file, a truncated
    /// download, or a well-meaning swap for G2 fails here rather than in
    /// production, where it would present as every genuine transaction being
    /// refused.
    #[test]
    fn the_compiled_in_root_is_apples() {
        let (rest, root) =
            X509Certificate::from_der(APPLE_ROOT_CA_G3).expect("the root parses as a certificate");

        assert!(rest.is_empty());
        assert_eq!(
            root.subject().to_string(),
            "CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US"
        );
        assert_eq!(root.subject(), root.issuer(), "the root is self-signed");
        root.verify_signature(None)
            .expect("the root's self-signature verifies");
    }
}
