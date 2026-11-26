use rdp_core::{EngineConfig, cert_sha256_hex, engine_info, supported_pcm_format_tag};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RdpEngineSummary {
    pub name: String,
    pub version: String,
    pub supports_rdpsnd: bool,
    pub tls_provider: String,
    pub pcm_format_tag: u16,
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_engine_summary() -> RdpEngineSummary {
    let info = engine_info();
    RdpEngineSummary {
        name: info.name.to_string(),
        version: info.version.to_string(),
        supports_rdpsnd: info.supports_rdpsnd,
        tls_provider: info.tls_provider.to_string(),
        pcm_format_tag: supported_pcm_format_tag(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn validate_endpoint(host: String, port: u16, width: u16, height: u16) -> anyhow::Result<()> {
    let cfg = EngineConfig {
        host,
        port,
        width,
        height,
    };
    cfg.validate().map_err(anyhow::Error::from)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fingerprint_sha256_hex(der_bytes: Vec<u8>) -> String {
    cert_sha256_hex(&der_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_summary_reflects_core_capabilities() {
        let summary = get_engine_summary();
        assert_eq!(summary.name, "aer-rdp-core");
        assert!(summary.supports_rdpsnd);
        assert_eq!(summary.tls_provider, "rustls-ring");
        assert_eq!(summary.pcm_format_tag, 1);
    }

    #[test]
    fn ffi_validate_endpoint_checks_inputs() {
        assert!(validate_endpoint("10.0.2.2".into(), 3389, 1920, 1080).is_ok());
        assert!(validate_endpoint("".into(), 3389, 1920, 1080).is_err());
        assert!(validate_endpoint("10.0.2.2".into(), 0, 1920, 1080).is_err());
    }

    #[test]
    fn ffi_fingerprint_matches_sha256() {
        assert_eq!(
            fingerprint_sha256_hex(b"abc".to_vec()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
