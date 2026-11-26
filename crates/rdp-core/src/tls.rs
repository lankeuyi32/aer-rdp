use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, Mutex};

use der::Decode as _;
use der::asn1::{Ia5StringRef, ObjectIdentifier, PrintableStringRef, TeletexStringRef, Utf8StringRef};
use rustls::DigitallySignedStruct;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use tokio::net::TcpStream;
use x509_cert::Certificate;
use x509_cert::ext::pkix::{SubjectAltName, name::GeneralName};

use crate::cert_sha256_hex;
use crate::types::{CertInfo, CoreError};

const OID_COMMON_NAME: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.3");
const OID_SUBJECT_ALT_NAME: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.17");

#[derive(Debug, Clone)]
struct CapturedCert {
    info: CertInfo,
    spki_pub_key: Vec<u8>,
}

#[derive(Debug)]
struct CapturingCertVerifier {
    algs: rustls::crypto::WebPkiSupportedAlgorithms,
    captured: Arc<Mutex<Option<CapturedCert>>>,
}

impl ServerCertVerifier for CapturingCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let der_bytes = end_entity.as_ref().to_vec();
        let (info, spki_pub_key) = parse_x509_cert_info(&der_bytes)
            .map_err(|e| rustls::Error::General(format!("failed to parse X.509 server cert: {e}")))?;

        let mut guard = self
            .captured
            .lock()
            .map_err(|_| rustls::Error::General("cert capture mutex poisoned".to_owned()))?;
        *guard = Some(CapturedCert { info, spki_pub_key });

        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algs)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.algs.supported_schemes()
    }
}

pub fn parse_x509_cert_info(der_bytes: &[u8]) -> Result<(CertInfo, Vec<u8>), CoreError> {
    let cert = Certificate::from_der(der_bytes)
        .map_err(|e| CoreError::Tls(format!("invalid DER certificate: {e}")))?;

    let sha256_hex = cert_sha256_hex(der_bytes);

    let mut subject_cn = None;
    for rdn in &cert.tbs_certificate.subject.0 {
        for atv in rdn.0.iter() {
            if atv.oid == OID_COMMON_NAME
                && let Some(decoded) = decode_directory_string(&atv.value)
            {
                subject_cn = Some(decoded);
                break;
            }
        }
        if subject_cn.is_some() {
            break;
        }
    }

    let mut san_entries = Vec::new();
    if let Some(extensions) = &cert.tbs_certificate.extensions {
        for ext in extensions {
            if ext.extn_id == OID_SUBJECT_ALT_NAME
                && let Ok(san) = SubjectAltName::from_der(ext.extn_value.as_bytes())
            {
                for gn in san.0 {
                    match gn {
                        GeneralName::DnsName(dns) => san_entries.push(format!("DNS:{}", dns.as_str())),
                        GeneralName::IpAddress(ip) => {
                            let bytes = ip.as_bytes();
                            if bytes.len() == 4 {
                                let addr = Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]);
                                san_entries.push(format!("IP:{addr}"));
                            } else if bytes.len() == 16 {
                                let octets: [u8; 16] = bytes.try_into().expect("16 bytes");
                                let addr = Ipv6Addr::from(octets);
                                san_entries.push(format!("IP:{addr}"));
                            }
                        }
                        GeneralName::Rfc822Name(mail) => san_entries.push(format!("email:{}", mail.as_str())),
                        GeneralName::UniformResourceIdentifier(uri) => {
                            san_entries.push(format!("URI:{}", uri.as_str()));
                        }
                        GeneralName::DirectoryName(dir) => san_entries.push(format!("DirName:{dir}")),
                        _ => {}
                    }
                }
            }
        }
    }

    let issuer = cert.tbs_certificate.issuer.to_string();
    let not_before = cert.tbs_certificate.validity.not_before.to_string();
    let not_after = cert.tbs_certificate.validity.not_after.to_string();

    let spki_pub_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or_else(|| CoreError::Tls("server certificate missing SPKI bit string".to_owned()))?
        .to_vec();

    Ok((
        CertInfo {
            sha256_hex,
            subject_cn,
            san_entries,
            issuer,
            not_before,
            not_after,
            der_bytes: der_bytes.to_vec(),
        },
        spki_pub_key,
    ))
}

fn decode_directory_string(any: &der::Any) -> Option<String> {
    if let Ok(s) = Utf8StringRef::try_from(any) {
        return Some(s.as_str().to_owned());
    }
    if let Ok(s) = PrintableStringRef::try_from(any) {
        return Some(s.as_str().to_owned());
    }
    if let Ok(s) = Ia5StringRef::try_from(any) {
        return Some(s.as_str().to_owned());
    }
    if let Ok(s) = TeletexStringRef::try_from(any) {
        return Some(s.as_str().to_owned());
    }
    String::from_utf8(any.value().to_vec()).ok()
}

fn server_name_from_host(host: &str) -> Result<ServerName<'static>, CoreError> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ServerName::IpAddress(ip.into()));
    }
    ServerName::try_from(host.to_owned())
        .map_err(|e| CoreError::Tls(format!("invalid TLS server name '{host}': {e}")))
}

pub async fn connect_and_inspect(
    tcp_stream: TcpStream,
    host: &str,
) -> Result<(ironrdp_tls::TlsStream<TcpStream>, CertInfo, Vec<u8>), CoreError> {
    let provider: CryptoProvider = rustls::crypto::ring::default_provider();
    let algs = provider.signature_verification_algorithms;
    let captured = Arc::new(Mutex::new(None));

    let verifier = Arc::new(CapturingCertVerifier {
        algs,
        captured: Arc::clone(&captured),
    });

    let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(provider))
        .with_safe_default_protocol_versions()
        .map_err(|e| CoreError::Tls(format!("TLS protocol version config failed: {e}")))?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();

    // CredSSP/NLA forbids TLS session resumption (pubKeyAuth binds to the handshake).
    config.resumption = rustls::client::Resumption::disabled();

    let server_name = server_name_from_host(host)?;
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let tls_stream = connector
        .connect(server_name, tcp_stream)
        .await
        .map_err(|e| CoreError::Tls(format!("TLS handshake failed: {e}")))?;

    let captured_cert = captured
        .lock()
        .map_err(|_| CoreError::Tls("cert capture mutex poisoned".to_owned()))?
        .take()
        .ok_or_else(|| CoreError::Tls("server presented no certificate during TLS handshake".to_owned()))?;

    Ok((tls_stream, captured_cert.info, captured_cert.spki_pub_key))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capturing_verifier_exposes_ring_signature_schemes() {
        let provider = rustls::crypto::ring::default_provider();
        let verifier = CapturingCertVerifier {
            algs: provider.signature_verification_algorithms,
            captured: Arc::new(Mutex::new(None)),
        };

        let schemes = verifier.supported_verify_schemes();
        assert!(schemes.contains(&rustls::SignatureScheme::ECDSA_NISTP256_SHA256));
        assert!(schemes.contains(&rustls::SignatureScheme::RSA_PSS_SHA256));
    }

    #[tokio::test]
    async fn tls_handshake_rejects_bogus_server_bytes() {
        use tokio::io::AsyncWriteExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut s, _)) = listener.accept().await {
                let _ = s.write_all(b"NOT_TLS").await;
            }
        });
        let tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let err = connect_and_inspect(tcp, "127.0.0.1").await.unwrap_err();
        assert!(matches!(err, CoreError::Tls(_)));
    }

    #[test]
    fn parse_x509_rejects_garbage_der() {
        let err = parse_x509_cert_info(b"not-a-cert").unwrap_err();
        assert!(matches!(err, CoreError::Tls(_)));
    }
}
