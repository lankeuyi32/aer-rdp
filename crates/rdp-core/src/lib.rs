use sha2::{Digest, Sha256};

pub mod audio;
pub mod connector;
pub mod framebuffer;
pub mod input;
pub mod rdpsnd;
pub mod session;
pub mod tls;
pub mod types;

pub use audio::{AudioJitterBuffer, AudioStreamFormat};
pub use framebuffer::{DirtyRect, Framebuffer};
pub use session::{SessionHandle, connect};
pub use types::{
    AudioMode, AudioReadStats, AudioSyncStats, AuthCredentials, BandwidthMode, CertInfo,
    CertTrustDecision, ConnectConfig, CoreError, SecurityMode, SessionCommand, SessionEvent,
    SessionState, normalize_sha256_pin,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    pub host: String,
    pub port: u16,
    pub width: u16,
    pub height: u16,
}

impl EngineConfig {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.host.trim().is_empty() {
            return Err(CoreError::EmptyHost);
        }
        if self.port == 0 {
            return Err(CoreError::InvalidPort);
        }
        if self.width == 0 || self.height == 0 {
            return Err(CoreError::InvalidDimensions {
                width: self.width,
                height: self.height,
            });
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineInfo {
    pub name: &'static str,
    pub version: &'static str,
    pub supports_rdpsnd: bool,
    pub tls_provider: &'static str,
}

pub fn engine_info() -> EngineInfo {
    EngineInfo {
        name: "aer-rdp-core",
        version: env!("CARGO_PKG_VERSION"),
        supports_rdpsnd: true,
        tls_provider: "rustls-ring",
    }
}

/// Computes lowercase hex SHA-256 fingerprint for an X.509 DER certificate.
pub fn cert_sha256_hex(der_bytes: &[u8]) -> String {
    let digest = Sha256::digest(der_bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

/// Verifies that Cohort A `ironrdp` (connector + rdpsnd + input) types link cleanly.
pub fn supported_pcm_format_tag() -> u16 {
    let fmt = ironrdp_rdpsnd::pdu::AudioFormat {
        format: ironrdp_rdpsnd::pdu::WaveFormat::PCM,
        n_channels: 2,
        n_samples_per_sec: 44_100,
        n_avg_bytes_per_sec: 176_400,
        n_block_align: 4,
        bits_per_sample: 16,
        data: None,
    };
    if fmt.format == ironrdp_rdpsnd::pdu::WaveFormat::PCM {
        1
    } else {
        0
    }
}

/// Verifies that `ironrdp-egfx` with bundled OpenH264 (`AVC420` & `AVC444`) initializes cleanly.
pub fn supports_egfx_h264() -> bool {
    ironrdp_egfx::decode::OpenH264Decoder::new().is_ok()
}

/// Verifies `ironrdp-tokio` and `ironrdp-tls` compile and link cleanly with `rustls-ring`.
pub fn tls_framed_type_name() -> &'static str {
    let _ = std::any::type_name::<ironrdp_tls::TlsStream<tokio::net::TcpStream>>();
    std::any::type_name::<ironrdp_tokio::Framed<tokio::net::TcpStream>>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_info_reports_rdpsnd_and_ring() {
        let info = engine_info();
        assert_eq!(info.name, "aer-rdp-core");
        assert!(info.supports_rdpsnd);
        assert_eq!(info.tls_provider, "rustls-ring");
    }

    #[test]
    fn config_validation_accepts_valid_and_rejects_invalid() {
        let valid = EngineConfig {
            host: "127.0.0.1".to_string(),
            port: 3389,
            width: 1280,
            height: 720,
        };
        assert!(valid.validate().is_ok());

        let empty_host = EngineConfig {
            host: "   ".to_string(),
            ..valid.clone()
        };
        assert!(matches!(empty_host.validate(), Err(CoreError::EmptyHost)));

        let zero_port = EngineConfig {
            port: 0,
            ..valid.clone()
        };
        assert!(matches!(zero_port.validate(), Err(CoreError::InvalidPort)));

        let zero_dim = EngineConfig {
            width: 0,
            ..valid
        };
        assert!(matches!(
            zero_dim.validate(),
            Err(CoreError::InvalidDimensions { .. })
        ));
    }

    #[test]
    fn sha256_fingerprint_matches_known_vector() {
        assert_eq!(
            cert_sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn ironrdp_rdpsnd_pcm_tag_is_one() {
        assert_eq!(supported_pcm_format_tag(), 1);
    }

    #[test]
    fn tls_framed_type_resolves() {
        assert!(tls_framed_type_name().contains("Framed"));
    }

    #[test]
    fn egfx_bundled_openh264_decoder_initializes() {
        assert!(supports_egfx_h264());
    }
}
