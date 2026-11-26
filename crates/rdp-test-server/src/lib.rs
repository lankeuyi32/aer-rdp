use std::net::SocketAddr;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestServerConfig {
    pub bind_addr: SocketAddr,
    pub desktop_width: u16,
    pub desktop_height: u16,
    pub audio_hz: u32,
}

impl Default for TestServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: ([127, 0, 0, 1], 3389).into(),
            desktop_width: 1280,
            desktop_height: 720,
            audio_hz: 440,
        }
    }
}

impl TestServerConfig {
    pub fn desktop_size(&self) -> ironrdp_server::DesktopSize {
        ironrdp_server::DesktopSize {
            width: self.desktop_width,
            height: self.desktop_height,
        }
    }
}

pub fn default_desktop_size() -> ironrdp_server::DesktopSize {
    TestServerConfig::default().desktop_size()
}

pub fn default_platform_type() -> ironrdp::pdu::rdp::capability_sets::MajorPlatformType {
    ironrdp::pdu::rdp::capability_sets::MajorPlatformType::WINDOWS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_produces_valid_ironrdp_desktop_size() {
        let size = default_desktop_size();
        assert_eq!(size.width, 1280);
        assert_eq!(size.height, 720);
    }

    #[test]
    fn custom_config_preserves_bind_addr_and_audio() {
        let cfg = TestServerConfig {
            bind_addr: ([127, 0, 0, 1], 13389).into(),
            desktop_width: 1920,
            desktop_height: 1080,
            audio_hz: 880,
        };
        assert_eq!(cfg.bind_addr.port(), 13389);
        assert_eq!(cfg.audio_hz, 880);
        assert_eq!(cfg.desktop_size().width, 1920);
    }

    #[test]
    fn default_platform_is_windows() {
        assert_eq!(
            default_platform_type(),
            ironrdp::pdu::rdp::capability_sets::MajorPlatformType::WINDOWS
        );
    }
}
