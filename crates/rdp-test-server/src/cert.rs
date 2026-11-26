use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use const_oid::ObjectIdentifier;
use der::asn1::{BitString, OctetString, Utf8StringRef};
use der::{Any, Decode as _, Encode as _};
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_ASN1_SIGNING, EcdsaKeyPair, KeyPair as _};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};
use spki::{AlgorithmIdentifierOwned, SubjectPublicKeyInfoOwned};
use tokio_rustls::TlsAcceptor;
use x509_cert::Certificate;
use x509_cert::certificate::{TbsCertificate, Version};
use x509_cert::ext::Extension;
use x509_cert::ext::pkix::{BasicConstraints, SubjectAltName, name::GeneralName};
use x509_cert::name::{Name, RdnSequence, RelativeDistinguishedName};
use x509_cert::serial_number::SerialNumber;
use x509_cert::time::{Time, Validity};
use x509_cert::attr::AttributeTypeAndValue;

const OID_EC_PUBLIC_KEY: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.10045.2.1");
const OID_PRIME256V1: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.10045.3.1.7");
const OID_ECDSA_WITH_SHA256: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.10045.4.3.2");
const OID_COMMON_NAME: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.3");
const OID_SUBJECT_ALT_NAME: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.17");
const OID_BASIC_CONSTRAINTS: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.19");

#[derive(Clone)]
pub struct ServerIdentity {
    pub cert_der: Vec<u8>,
    pub cert_sha256: String,
    pub spki_pub_key: Vec<u8>,
    pub tls_acceptor: TlsAcceptor,
}

static DETERMINISTIC_CACHE: OnceLock<Mutex<HashMap<[u8; 32], Arc<ServerIdentity>>>> =
    OnceLock::new();

pub fn get_or_create_identity(seed: Option<[u8; 32]>) -> anyhow::Result<Arc<ServerIdentity>> {
    if let Some(s) = seed {
        let cache = DETERMINISTIC_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        if let Some(existing) = cache.lock().expect("cert cache lock").get(&s).cloned() {
            return Ok(existing);
        }
        let generated = Arc::new(generate_self_signed_p256(Some(s))?);
        cache
            .lock()
            .expect("cert cache lock")
            .insert(s, Arc::clone(&generated));
        return Ok(generated);
    }
    Ok(Arc::new(generate_self_signed_p256(None)?))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(&mut out, "{b:02x}");
    }
    out
}

fn generate_self_signed_p256(seed: Option<[u8; 32]>) -> anyhow::Result<ServerIdentity> {
    let rng = SystemRandom::new();
    let pkcs8_doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
        .map_err(|e| anyhow::anyhow!("ECDSA keygen failed: {e}"))?;
    let pkcs8_der = pkcs8_doc.as_ref().to_vec();
    let keypair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &pkcs8_der, &rng)
        .map_err(|e| anyhow::anyhow!("ECDSA keypair parse failed: {e}"))?;

    let cn_str = match seed {
        Some(s) => format!("aer-rdp-test-{:02x}{:02x}{:02x}{:02x}", s[0], s[1], s[2], s[3]),
        None => "aer-rdp-test.local".to_owned(),
    };

    let mut serial_bytes = [0x42u8; 16];
    if let Some(s) = seed {
        serial_bytes.copy_from_slice(&s[..16]);
    } else {
        ring::rand::SecureRandom::fill(&rng, &mut serial_bytes)
            .map_err(|e| anyhow::anyhow!("serial RNG failed: {e}"))?;
    }
    // Positive non-zero RFC5280 serial number
    serial_bytes[0] &= 0x7F;
    serial_bytes[0] |= 0x01;

    let cn_utf8 = Utf8StringRef::new(&cn_str)?;
    let cn_any = Any::from_der(&cn_utf8.to_der()?)?;
    let mut set_vec = der::asn1::SetOfVec::new();
    set_vec.insert(AttributeTypeAndValue {
        oid: OID_COMMON_NAME,
        value: cn_any,
    })?;
    let name: Name = RdnSequence(vec![RelativeDistinguishedName(set_vec)]);

    let curve_der = OID_PRIME256V1.to_der()?;
    let spki = SubjectPublicKeyInfoOwned {
        algorithm: AlgorithmIdentifierOwned {
            oid: OID_EC_PUBLIC_KEY,
            parameters: Some(Any::from_der(&curve_der)?),
        },
        subject_public_key: BitString::from_bytes(keypair.public_key().as_ref())?,
    };

    let sig_alg = AlgorithmIdentifierOwned {
        oid: OID_ECDSA_WITH_SHA256,
        parameters: None,
    };

    let not_before = Time::UtcTime(der::asn1::UtcTime::from_unix_duration(
        std::time::Duration::from_secs(1_735_689_600), // 2025-01-01T00:00:00Z
    )?);
    let not_after = Time::UtcTime(der::asn1::UtcTime::from_unix_duration(
        std::time::Duration::from_secs(2_051_222_400), // 2035-01-01T00:00:00Z
    )?);

    let san = SubjectAltName(vec![
        GeneralName::DnsName(der::asn1::Ia5String::new("localhost")?),
        GeneralName::IpAddress(OctetString::new(vec![127, 0, 0, 1])?),
    ]);
    let bc = BasicConstraints {
        ca: false,
        path_len_constraint: None,
    };

    let extensions = vec![
        Extension {
            extn_id: OID_BASIC_CONSTRAINTS,
            critical: true,
            extn_value: OctetString::new(bc.to_der()?)?,
        },
        Extension {
            extn_id: OID_SUBJECT_ALT_NAME,
            critical: false,
            extn_value: OctetString::new(san.to_der()?)?,
        },
    ];

    let tbs = TbsCertificate {
        version: Version::V3,
        serial_number: SerialNumber::new(&serial_bytes)?,
        signature: sig_alg.clone(),
        issuer: name.clone(),
        validity: Validity {
            not_before,
            not_after,
        },
        subject: name,
        subject_public_key_info: spki,
        issuer_unique_id: None,
        subject_unique_id: None,
        extensions: Some(extensions),
    };

    let tbs_der = tbs.to_der()?;
    let sig = keypair
        .sign(&rng, &tbs_der)
        .map_err(|e| anyhow::anyhow!("ECDSA sign failed: {e}"))?;

    let cert = Certificate {
        tbs_certificate: tbs,
        signature_algorithm: sig_alg,
        signature: BitString::from_bytes(sig.as_ref())?,
    };

    let cert_der = cert.to_der()?;
    let cert_sha256 = sha256_hex(&cert_der);
    let spki_pub_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or_else(|| anyhow::anyhow!("SPKI missing bitstring bytes"))?
        .to_vec();

    let server_config =
        rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert_der.clone())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(pkcs8_der)),
            )?;

    Ok(ServerIdentity {
        cert_der,
        cert_sha256,
        spki_pub_key,
        tls_acceptor: TlsAcceptor::from(Arc::new(server_config)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_seed_produces_identical_cert_across_restarts() {
        let seed_a = [0xAAu8; 32];
        let seed_b = [0xBBu8; 32];

        let id1 = get_or_create_identity(Some(seed_a)).unwrap();
        let id2 = get_or_create_identity(Some(seed_a)).unwrap();
        let id3 = get_or_create_identity(Some(seed_b)).unwrap();

        assert_eq!(id1.cert_sha256, id2.cert_sha256);
        assert_ne!(id1.cert_sha256, id3.cert_sha256);
        assert_eq!(id1.cert_sha256.len(), 64);

        let parsed = Certificate::from_der(&id1.cert_der).unwrap();
        assert_eq!(parsed.tbs_certificate.version, Version::V3);
    }
}
