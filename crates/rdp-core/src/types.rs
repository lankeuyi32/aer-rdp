use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Core error type for `rdp-core`.
///
/// Retains all M1 variants (`EmptyHost`, `InvalidPort`, `InvalidDimensions`) for backwards
/// compatibility with `crates/rdp-ffi`.
#[derive(Debug, Error)]
pub enum CoreError {
    #[error("host must not be empty")]
    EmptyHost,
    #[error("port must be non-zero")]
    InvalidPort,
    #[error("desktop dimensions must be non-zero ({width}x{height})")]
    InvalidDimensions { width: u16, height: u16 },
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("certificate rejected by user")]
    CertRejected,
    #[error("certificate fingerprint mismatch (expected {expected}, got {actual})")]
    CertMismatch {
        expected: String,
        actual: String,
        cert_info: Box<CertInfo>,
    },
    #[error("authentication failed: {0}")]
    AuthFailed(String),
    #[error("RDP connection negotiation failed: {0}")]
    Connector(String),
    #[error("RDP session error: {0}")]
    Session(String),
    #[error("command channel closed")]
    ChannelClosed,
    #[error("operation cancelled")]
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    Auto,
    Nla,
    Tls,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioMode {
    Local,
    Remote,
    Off,
}

#[derive(Debug, Clone)]
pub struct ConnectConfig {
    pub host: String,
    pub port: u16,
    /// Requested desktop width. Clamped to `[200, 8192]` and aligned down to a multiple of 4
    /// for `CS_CORE` compatibility.
    pub width: u16,
    /// Requested desktop height. Clamped to `[200, 8192]`.
    pub height: u16,
    pub scale_factor: u32,
    pub security_mode: SecurityMode,
    pub audio_mode: AudioMode,
    pub client_name: String,
    pub pinned_cert_sha256: Option<String>,
    pub enable_server_pointer: bool,
    pub pointer_software_rendering: bool,
}

impl Default for ConnectConfig {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 3389,
            width: 1280,
            height: 720,
            scale_factor: 100,
            security_mode: SecurityMode::Auto,
            audio_mode: AudioMode::Local,
            client_name: "aer-rdp".to_owned(),
            pinned_cert_sha256: None,
            enable_server_pointer: true,
            pointer_software_rendering: false,
        }
    }
}

impl ConnectConfig {
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

    /// Returns `(aligned_width, clamped_height)` suitable for `CS_CORE` (`width` multiple of 4).
    pub fn aligned_dimensions(&self) -> (u16, u16) {
        let w = (self.width.clamp(200, 8192)) & !3;
        let h = self.height.clamp(200, 8192);
        (w.max(200), h.max(200))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthCredentials {
    pub username: String,
    pub domain: Option<String>,
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertInfo {
    pub sha256_hex: String,
    pub subject_cn: Option<String>,
    pub san_entries: Vec<String>,
    pub issuer: String,
    pub not_before: String,
    pub not_after: String,
    pub der_bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CertTrustDecision {
    TrustOnce,
    TrustAlways,
    Reject,
}

#[derive(Debug, Clone)]
pub enum SessionCommand {
    SubmitCertDecision(CertTrustDecision),
    SubmitCredentials(AuthCredentials),
    SendPointer {
        x: u16,
        y: u16,
        button_mask: u8,
        down: bool,
        wheel_delta_v: i16,
        wheel_delta_h: i16,
    },
    SendScancode {
        code: u8,
        extended: bool,
        down: bool,
    },
    SendUnicode {
        code_unit: u16,
        down: bool,
    },
    SetAudioMute(bool),
    SetAudioVolume(f32),
    Disconnect,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Connecting,
    CertPrompt(CertInfo),
    AuthPrompt { reason: Option<String> },
    Active { width: u16, height: u16 },
    Reactivating,
    Disconnected { reason: String, clean: bool },
}

#[derive(Debug, Clone)]
pub enum SessionEvent {
    SessionStateChanged(SessionState),
    FrameUpdated {
        dirty_x: u16,
        dirty_y: u16,
        dirty_w: u16,
        dirty_h: u16,
        width: u16,
        height: u16,
        frame_sync: bool,
        presentation_ms: u64,
    },
    CursorUpdated {
        x: u16,
        y: u16,
        visible: bool,
        hotspot_x: u16,
        hotspot_y: u16,
        width: u16,
        height: u16,
        rgba_pixels: Vec<u8>,
    },
    AudioStreamOpened {
        sample_rate: u32,
        channels: u16,
        bits_per_sample: u16,
    },
    AudioVolumeChanged {
        left: u16,
        right: u16,
    },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioReadStats {
    pub frames_read: usize,
    pub queued_ms: u32,
    pub drift_ms: i64,
    pub drops: u64,
    pub underruns: u64,
    pub wave_confirms_sent: u64,
}

pub type AudioSyncStats = AudioReadStats;

pub fn normalize_sha256_pin(raw: &str) -> String {
    let trimmed = raw.trim();
    let stripped = trimmed
        .strip_prefix("sha256:")
        .or_else(|| trimmed.strip_prefix("SHA256:"))
        .unwrap_or(trimmed);
    stripped
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect::<String>()
        .to_ascii_lowercase()
}
