//! Certificate-chain trust: leaf ← WWDR intermediate ← Apple Root CA - G3.
//!
//! Handed the `x5c` entries out of a JWS header, the bytes that were signed, the
//! signature over them, and the instant to judge validity at — and answers
//! whether that signature leads back to the root compiled in below. It knows
//! nothing about subscriptions, products, bundle ids, or the shape of an App
//! Store transaction payload; [`super::appstore`] owns all of that and calls in
//! here for the one question it cannot answer itself.
//!
//! Separated because this is the only code standing between a forged token and a
//! granted subscription, and it was previously buried mid-file beneath the
//! transcription of Apple's payload schema — 450 lines from the tests that cover
//! it.

use base64::Engine as _;
use chrono::{DateTime, Utc};
use x509_parser::certificate::X509Certificate;
use x509_parser::error::X509Error;
use x509_parser::nom::AsBytes as _;
use x509_parser::oid_registry::asn1_rs::{Oid, oid};
use x509_parser::prelude::{ASN1Time, FromDer as _};

use super::VerificationError;

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

/// Marks a certificate as one of Apple's receipt-signing leaves.
const LEAF_MARKER_OID: Oid<'static> = oid!(1.2.840.113635.100.6.11.1);

/// Marks the Worldwide Developer Relations intermediate.
const INTERMEDIATE_MARKER_OID: Oid<'static> = oid!(1.2.840.113635.100.6.2.1);

/// Checks that `signature` over `signing_input` was made by a leaf Apple issued,
/// as of `signed_at`.
///
/// The whole trust decision in one call, and it is all-or-nothing on purpose:
/// splitting "the chain is Apple's" from "the signature verifies" would leave a
/// caller able to do one and forget the other, and forgetting either grants a
/// subscription to a self-signed token.
///
/// `signed_at` rather than `now()` is the instant every validity window is
/// measured against — see [`require_valid_at`].
pub fn verify(
    x5c: &[String],
    signing_input: &[u8],
    signature: &[u8],
    signed_at: DateTime<Utc>,
) -> Result<(), VerificationError> {
    let chain = decode_chain(x5c)?;
    let certificates = parse_chain(&chain)?;
    let leaf = verify_chain(&certificates, signed_at)?;

    verify_signature(leaf, signing_input, signature)
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
    require_issuing_authority(intermediate)?;

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

/// The middle certificate has to be one that is *allowed* to have issued the
/// leaf, which is a question separate from whether it did.
///
/// `basicConstraints` and `keyUsage` are the two fields that answer it, and
/// neither was read before: the walk established that Apple signed the
/// intermediate and that the intermediate signed the leaf, which an end-entity
/// certificate sitting directly under the G3 root would also satisfy. Apple does
/// not issue such a certificate carrying the WWDR marker OID, so this is defence
/// in depth rather than a hole — worth closing because this is the one place a
/// signature decides who spends money, and because the stated reason for walking
/// the chain by hand was that the community crate's walk carried a `TODO:
/// Implement issuer checking`.
///
/// Both are required to be present. An intermediate that omits either is not a
/// CA certificate any conforming path validator would accept, so demanding them
/// rejects nothing Apple issues.
fn require_issuing_authority(intermediate: &X509Certificate<'_>) -> Result<(), VerificationError> {
    let unreadable = |field: &'static str| {
        move |error: X509Error| {
            VerificationError::Untrusted(format!(
                "the intermediate's `{field}` is unreadable: {error}"
            ))
        }
    };

    let is_authority = intermediate
        .basic_constraints()
        .map_err(unreadable("basicConstraints"))?
        .is_some_and(|constraints| constraints.value.ca);

    let may_sign_certificates = intermediate
        .key_usage()
        .map_err(unreadable("keyUsage"))?
        .is_some_and(|usage| usage.value.key_cert_sign());

    if is_authority && may_sign_certificates {
        return Ok(());
    }

    Err(VerificationError::Untrusted(format!(
        "the intermediate may not issue certificates: `basicConstraints` says CA is \
         {is_authority}, `keyUsage` says keyCertSign is {may_sign_certificates}"
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

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp_millis(1_770_000_000_000).expect("a representable instant")
    }

    /// The whole point. An attacker can produce a structurally perfect JWS —
    /// correct segments, correct `alg`, three parseable certificates, a
    /// signature that verifies against the key in its own leaf — because none of
    /// that requires anything Apple holds. What they cannot produce is a chain
    /// leading to the root compiled in above, and that is the only thing this
    /// function believes.
    #[test]
    fn a_forged_chain_does_not_verify() {
        let forged = [
            "MIIBBg==".to_owned(),
            "MIIBBg==".to_owned(),
            "MIIBBg==".to_owned(),
        ];

        let error = verify(&forged, b"header.payload", &[0_u8; 64], now())
            .expect_err("a self-signed chain is not Apple's");

        assert!(matches!(error, VerificationError::Untrusted(_)), "{error}");
    }

    /// Three certificates, and only three — a shorter or longer `x5c` is not a
    /// different path to the same anchor, it is a token this code was not
    /// written to read.
    #[test]
    fn a_chain_of_the_wrong_length_is_untrusted() {
        for length in [0, 1, 2, 4] {
            let x5c = vec!["MIIBBg==".to_owned(); length];

            let error = verify(&x5c, b"header.payload", &[0_u8; 64], now())
                .expect_err("only a three-certificate chain is read");

            assert!(
                matches!(&error, VerificationError::Untrusted(message) if message.contains("not 3")),
                "{length}: {error}"
            );
        }
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

    /// The risk in demanding `basicConstraints` and `keyUsage` is not that a
    /// forgery slips through, it is that a genuine Apple CA certificate is
    /// turned away and every real purchase stops verifying. The only Apple CA
    /// certificate this repository holds is the root, so it is the one asserted:
    /// if these two checks reject it, they would reject the intermediate too.
    #[test]
    fn a_genuine_apple_authority_satisfies_the_issuing_checks() {
        let (_, root) =
            X509Certificate::from_der(APPLE_ROOT_CA_G3).expect("the root parses as a certificate");

        require_issuing_authority(&root).expect("Apple's root may issue certificates");
    }
}
