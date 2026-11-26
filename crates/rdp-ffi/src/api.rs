use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;
use rdp_core::{
    AudioJitterBuffer, AudioMode, AuthCredentials, CertInfo, CertTrustDecision, ConnectConfig,
    DirtyRect, EngineConfig, SecurityMode, SessionEvent, SessionHandle, SessionState,
    cert_sha256_hex, connect, engine_info, supported_pcm_format_tag,
};

use crate::frb_generated::StreamSink;

static TOKIO_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("aer-rdp-tokio")
            .build()
            .expect("failed to build Tokio runtime for rdp-ffi")
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RdpEngineSummary {
    pub name: String,
    pub version: String,
    pub supports_rdpsnd: bool,
    pub tls_provider: String,
    pub pcm_format_tag: u16,
}

#[frb(sync)]
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

#[frb(sync)]
pub fn validate_endpoint(host: String, port: u16, width: u16, height: u16) -> anyhow::Result<()> {
    let cfg = EngineConfig {
        host,
        port,
        width,
        height,
    };
    cfg.validate().map_err(anyhow::Error::from)
}

#[frb(sync)]
pub fn fingerprint_sha256_hex(der_bytes: Vec<u8>) -> String {
    cert_sha256_hex(&der_bytes)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSecurityMode {
    Auto,
    Nla,
    Tls,
}

impl From<FfiSecurityMode> for SecurityMode {
    fn from(value: FfiSecurityMode) -> Self {
        match value {
            FfiSecurityMode::Auto => SecurityMode::Auto,
            FfiSecurityMode::Nla => SecurityMode::Nla,
            FfiSecurityMode::Tls => SecurityMode::Tls,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiAudioMode {
    Local,
    Remote,
    Off,
}

impl From<FfiAudioMode> for AudioMode {
    fn from(value: FfiAudioMode) -> Self {
        match value {
            FfiAudioMode::Local => AudioMode::Local,
            FfiAudioMode::Remote => AudioMode::Remote,
            FfiAudioMode::Off => AudioMode::Off,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiCertTrustDecision {
    TrustOnce,
    TrustAlways,
    Reject,
}

impl From<FfiCertTrustDecision> for CertTrustDecision {
    fn from(value: FfiCertTrustDecision) -> Self {
        match value {
            FfiCertTrustDecision::TrustOnce => CertTrustDecision::TrustOnce,
            FfiCertTrustDecision::TrustAlways => CertTrustDecision::TrustAlways,
            FfiCertTrustDecision::Reject => CertTrustDecision::Reject,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiConnectConfig {
    pub host: String,
    pub port: u16,
    pub width: u16,
    pub height: u16,
    pub scale_factor: u32,
    pub security_mode: FfiSecurityMode,
    pub audio_mode: FfiAudioMode,
    pub client_name: String,
    pub pinned_cert_sha256: Option<String>,
    pub enable_server_pointer: bool,
    pub pointer_software_rendering: bool,
}

impl FfiConnectConfig {
    fn to_core_config(&self) -> ConnectConfig {
        ConnectConfig {
            host: self.host.clone(),
            port: self.port,
            width: self.width,
            height: self.height,
            scale_factor: self.scale_factor,
            security_mode: self.security_mode.into(),
            audio_mode: self.audio_mode.into(),
            client_name: if self.client_name.trim().is_empty() {
                "aer-rdp".to_owned()
            } else {
                self.client_name.clone()
            },
            pinned_cert_sha256: self.pinned_cert_sha256.clone(),
            enable_server_pointer: self.enable_server_pointer,
            pointer_software_rendering: self.pointer_software_rendering,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiCredentials {
    pub username: String,
    pub domain: Option<String>,
    pub password: String,
}

impl From<FfiCredentials> for AuthCredentials {
    fn from(value: FfiCredentials) -> Self {
        Self {
            username: value.username,
            domain: value.domain,
            password: value.password,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiCertInfo {
    pub sha256_hex: String,
    pub subject_cn: Option<String>,
    pub san_entries: Vec<String>,
    pub issuer: String,
    pub not_before: String,
    pub not_after: String,
    pub der_bytes: Vec<u8>,
}

impl From<CertInfo> for FfiCertInfo {
    fn from(value: CertInfo) -> Self {
        Self {
            sha256_hex: value.sha256_hex,
            subject_cn: value.subject_cn,
            san_entries: value.san_entries,
            issuer: value.issuer,
            not_before: value.not_before,
            not_after: value.not_after,
            der_bytes: value.der_bytes,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSessionStateKind {
    Connecting,
    CertPrompt,
    AuthPrompt,
    Active,
    Reactivating,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiSessionState {
    pub kind: FfiSessionStateKind,
    pub cert: Option<FfiCertInfo>,
    pub reason: Option<String>,
    pub width: u16,
    pub height: u16,
    pub clean: bool,
}

impl From<SessionState> for FfiSessionState {
    fn from(value: SessionState) -> Self {
        match value {
            SessionState::Connecting => Self {
                kind: FfiSessionStateKind::Connecting,
                cert: None,
                reason: None,
                width: 0,
                height: 0,
                clean: false,
            },
            SessionState::CertPrompt(cert) => Self {
                kind: FfiSessionStateKind::CertPrompt,
                cert: Some(cert.into()),
                reason: None,
                width: 0,
                height: 0,
                clean: false,
            },
            SessionState::AuthPrompt { reason } => Self {
                kind: FfiSessionStateKind::AuthPrompt,
                cert: None,
                reason,
                width: 0,
                height: 0,
                clean: false,
            },
            SessionState::Active { width, height } => Self {
                kind: FfiSessionStateKind::Active,
                cert: None,
                reason: None,
                width,
                height,
                clean: false,
            },
            SessionState::Reactivating => Self {
                kind: FfiSessionStateKind::Reactivating,
                cert: None,
                reason: None,
                width: 0,
                height: 0,
                clean: false,
            },
            SessionState::Disconnected { reason, clean } => Self {
                kind: FfiSessionStateKind::Disconnected,
                cert: None,
                reason: Some(reason),
                width: 0,
                height: 0,
                clean,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSessionEventKind {
    StateChanged,
    FrameUpdated,
    CursorUpdated,
    AudioStreamOpened,
    AudioVolumeChanged,
}

#[derive(Debug, Clone)]
pub struct FfiSessionEvent {
    pub kind: FfiSessionEventKind,
    pub state: Option<FfiSessionState>,
    pub dirty_x: u16,
    pub dirty_y: u16,
    pub dirty_w: u16,
    pub dirty_h: u16,
    pub width: u16,
    pub height: u16,
    pub frame_sync: bool,
    pub presentation_ms: u64,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub cursor_hotspot_x: u16,
    pub cursor_hotspot_y: u16,
    pub cursor_rgba_pixels: Vec<u8>,
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub volume_left: u16,
    pub volume_right: u16,
}

impl From<SessionEvent> for FfiSessionEvent {
    fn from(value: SessionEvent) -> Self {
        let mut out = Self {
            kind: FfiSessionEventKind::StateChanged,
            state: None,
            dirty_x: 0,
            dirty_y: 0,
            dirty_w: 0,
            dirty_h: 0,
            width: 0,
            height: 0,
            frame_sync: false,
            presentation_ms: 0,
            cursor_x: 0,
            cursor_y: 0,
            cursor_visible: false,
            cursor_hotspot_x: 0,
            cursor_hotspot_y: 0,
            cursor_rgba_pixels: Vec::new(),
            sample_rate: 0,
            channels: 0,
            bits_per_sample: 0,
            volume_left: 0,
            volume_right: 0,
        };
        match value {
            SessionEvent::SessionStateChanged(state) => {
                out.kind = FfiSessionEventKind::StateChanged;
                out.state = Some(state.into());
            }
            SessionEvent::FrameUpdated {
                dirty_x,
                dirty_y,
                dirty_w,
                dirty_h,
                width,
                height,
                frame_sync,
                presentation_ms,
            } => {
                out.kind = FfiSessionEventKind::FrameUpdated;
                out.dirty_x = dirty_x;
                out.dirty_y = dirty_y;
                out.dirty_w = dirty_w;
                out.dirty_h = dirty_h;
                out.width = width;
                out.height = height;
                out.frame_sync = frame_sync;
                out.presentation_ms = presentation_ms;
            }
            SessionEvent::CursorUpdated {
                x,
                y,
                visible,
                hotspot_x,
                hotspot_y,
                width,
                height,
                rgba_pixels,
            } => {
                out.kind = FfiSessionEventKind::CursorUpdated;
                out.cursor_x = x;
                out.cursor_y = y;
                out.cursor_visible = visible;
                out.cursor_hotspot_x = hotspot_x;
                out.cursor_hotspot_y = hotspot_y;
                out.width = width;
                out.height = height;
                out.cursor_rgba_pixels = rgba_pixels;
            }
            SessionEvent::AudioStreamOpened {
                sample_rate,
                channels,
                bits_per_sample,
            } => {
                out.kind = FfiSessionEventKind::AudioStreamOpened;
                out.sample_rate = sample_rate;
                out.channels = channels;
                out.bits_per_sample = bits_per_sample;
            }
            SessionEvent::AudioVolumeChanged { left, right } => {
                out.kind = FfiSessionEventKind::AudioVolumeChanged;
                out.volume_left = left;
                out.volume_right = right;
            }
        }
        out
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiFramePatch {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub fb_width: u16,
    pub fb_height: u16,
    pub is_full_frame: bool,
    pub rgba_bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiAudioReadResult {
    pub pcm_bytes: Vec<u8>,
    pub frames_read: u32,
    pub queued_ms: u32,
    pub drift_ms: i64,
    pub drops: u64,
    pub underruns: u64,
    pub wave_confirms_sent: u64,
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
}

fn coalesce_dirty_rect(slot: &Mutex<Option<DirtyRect>>, next: DirtyRect) {
    if next.w == 0 || next.h == 0 {
        return;
    }
    if let Ok(mut guard) = slot.lock() {
        *guard = Some(match *guard {
            Some(prev) => prev.union(next),
            None => next,
        });
    }
}

fn extract_frame_patch(
    fb_w: u16,
    fb_h: u16,
    data: &[u8],
    dirty: Option<DirtyRect>,
    force_full: bool,
) -> Option<FfiFramePatch> {
    if !force_full && dirty.is_none() {
        return None;
    }
    let expected_len = usize::from(fb_w) * usize::from(fb_h) * 4;
    if fb_w == 0 || fb_h == 0 || data.len() < expected_len {
        return None;
    }
    if force_full {
        return Some(FfiFramePatch {
            x: 0,
            y: 0,
            w: fb_w,
            h: fb_h,
            fb_width: fb_w,
            fb_height: fb_h,
            is_full_frame: true,
            rgba_bytes: data[..expected_len].to_vec(),
        });
    }

    let d = dirty?;
    if d.x >= fb_w || d.y >= fb_h || d.w == 0 || d.h == 0 {
        return None;
    }
    let x = d.x;
    let y = d.y;
    let w = d.w.min(fb_w - x);
    let h = d.h.min(fb_h - y);
    if w == 0 || h == 0 {
        return None;
    }

    let dirty_area = u64::from(w) * u64::from(h);
    let total_area = u64::from(fb_w) * u64::from(fb_h);
    if (x == 0 && y == 0 && w == fb_w && h == fb_h) || dirty_area * 2 >= total_area {
        return Some(FfiFramePatch {
            x: 0,
            y: 0,
            w: fb_w,
            h: fb_h,
            fb_width: fb_w,
            fb_height: fb_h,
            is_full_frame: true,
            rgba_bytes: data[..expected_len].to_vec(),
        });
    }

    let row_bytes = usize::from(w) * 4;
    let fb_stride = usize::from(fb_w) * 4;
    let mut out = Vec::with_capacity(usize::from(h) * row_bytes);
    for row in 0..usize::from(h) {
        let start = (usize::from(y) + row) * fb_stride + usize::from(x) * 4;
        out.extend_from_slice(&data[start..start + row_bytes]);
    }
    Some(FfiFramePatch {
        x,
        y,
        w,
        h,
        fb_width: fb_w,
        fb_height: fb_h,
        is_full_frame: false,
        rgba_bytes: out,
    })
}

fn read_audio_from_buffer(
    jb: &mut AudioJitterBuffer,
    requested_frames: u32,
    frames_played_since_last_read: u32,
) -> FfiAudioReadResult {
    let fmt = jb.format();
    let frame_bytes = fmt.frame_bytes().max(1);
    let queued = jb.queued_frames();

    if queued == 0 || requested_frames == 0 {
        let stats = jb.read_pcm_frames(&mut [], frames_played_since_last_read as usize);
        return FfiAudioReadResult {
            pcm_bytes: Vec::new(),
            frames_read: 0,
            queued_ms: stats.queued_ms,
            drift_ms: stats.drift_ms,
            drops: stats.drops,
            underruns: stats.underruns,
            wave_confirms_sent: stats.wave_confirms_sent,
            sample_rate: fmt.sample_rate,
            channels: fmt.channels,
            bits_per_sample: fmt.bits_per_sample,
        };
    }

    let mut buf = vec![0u8; requested_frames as usize * frame_bytes];
    let stats = jb.read_pcm_frames(&mut buf, frames_played_since_last_read as usize);
    buf.truncate(stats.frames_read * frame_bytes);
    FfiAudioReadResult {
        pcm_bytes: buf,
        frames_read: stats.frames_read as u32,
        queued_ms: stats.queued_ms,
        drift_ms: stats.drift_ms,
        drops: stats.drops,
        underruns: stats.underruns,
        wave_confirms_sent: stats.wave_confirms_sent,
        sample_rate: fmt.sample_rate,
        channels: fmt.channels,
        bits_per_sample: fmt.bits_per_sample,
    }
}

#[frb(opaque)]
pub struct FfiSessionHandle {
    inner: SessionHandle,
    pending_dirty: Arc<Mutex<Option<DirtyRect>>>,
    event_rx: Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<SessionEvent>>>,
}

#[frb(sync)]
pub fn create_session(
    config: FfiConnectConfig,
    initial_creds: Option<FfiCredentials>,
) -> anyhow::Result<FfiSessionHandle> {
    let _guard = runtime().enter();
    let (handle, event_rx) = connect(config.to_core_config(), initial_creds.map(Into::into))?;
    Ok(FfiSessionHandle {
        inner: handle,
        pending_dirty: Arc::new(Mutex::new(None)),
        event_rx: Mutex::new(Some(event_rx)),
    })
}

impl FfiSessionHandle {
    pub fn subscribe_events(&self, events: StreamSink<FfiSessionEvent>) -> anyhow::Result<()> {
        let mut rx = self
            .event_rx
            .lock()
            .map_err(|_| anyhow::anyhow!("event_rx mutex poisoned"))?
            .take()
            .ok_or_else(|| anyhow::anyhow!("session events already subscribed"))?;
        let pending_dirty_task = Arc::clone(&self.pending_dirty);

        runtime().spawn(async move {
            while let Some(ev) = rx.recv().await {
                match &ev {
                    SessionEvent::FrameUpdated {
                        dirty_x,
                        dirty_y,
                        dirty_w,
                        dirty_h,
                        ..
                    } => {
                        coalesce_dirty_rect(
                            &pending_dirty_task,
                            DirtyRect {
                                x: *dirty_x,
                                y: *dirty_y,
                                w: *dirty_w,
                                h: *dirty_h,
                            },
                        );
                    }
                    SessionEvent::SessionStateChanged(SessionState::Active { width, height }) => {
                        coalesce_dirty_rect(
                            &pending_dirty_task,
                            DirtyRect {
                                x: 0,
                                y: 0,
                                w: *width,
                                h: *height,
                            },
                        );
                    }
                    _ => {}
                }
                if events.add(FfiSessionEvent::from(ev)).is_err() {
                    break;
                }
            }
        });

        Ok(())
    }
    #[frb(sync)]
    pub fn submit_cert_decision(&self, decision: FfiCertTrustDecision) -> anyhow::Result<()> {
        self.inner
            .submit_cert_decision(decision.into())
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn submit_credentials(&self, creds: FfiCredentials) -> anyhow::Result<()> {
        self.inner
            .submit_credentials(creds.into())
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn send_pointer_event(
        &self,
        x: u16,
        y: u16,
        button_mask: u8,
        down: bool,
        wheel_delta_v: i16,
        wheel_delta_h: i16,
    ) -> anyhow::Result<()> {
        self.inner
            .send_pointer_event_hv(x, y, button_mask, down, wheel_delta_v, wheel_delta_h)
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn send_scancode(&self, code: u8, extended: bool, down: bool) -> anyhow::Result<()> {
        self.inner
            .send_scancode(code, extended, down)
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn send_unicode(&self, code_unit: u16, down: bool) -> anyhow::Result<()> {
        self.inner
            .send_unicode(code_unit, down)
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn set_audio_mute(&self, muted: bool) -> anyhow::Result<()> {
        if let Ok(mut jb) = self.inner.audio_buffer().lock() {
            jb.set_muted(muted);
        }
        self.inner
            .set_audio_mute(muted)
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn set_audio_volume(&self, volume: f32) -> anyhow::Result<()> {
        if let Ok(mut jb) = self.inner.audio_buffer().lock() {
            jb.set_user_volume(volume);
        }
        self.inner
            .set_audio_volume(volume)
            .map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn disconnect(&self) -> anyhow::Result<()> {
        self.inner.disconnect().map_err(anyhow::Error::from)
    }

    #[frb(sync)]
    pub fn cert_info(&self) -> Option<FfiCertInfo> {
        self.inner.cert_info().map(Into::into)
    }

    #[frb(sync)]
    pub fn framebuffer_sha256_hex(&self) -> String {
        self.inner.framebuffer_sha256_hex()
    }

    pub async fn take_frame_patch(&self, force_full: bool) -> Option<FfiFramePatch> {
        let dirty = self
            .pending_dirty
            .lock()
            .ok()
            .and_then(|mut guard| guard.take());
        self.inner
            .with_framebuffer_rgba(|fb_w, fb_h, data| extract_frame_patch(fb_w, fb_h, data, dirty, force_full))
    }

    #[frb(sync)]
    pub fn read_audio_pcm(
        &self,
        requested_frames: u32,
        frames_played_since_last_read: u32,
    ) -> FfiAudioReadResult {
        let audio_buf = self.inner.audio_buffer();
        let mut jb = audio_buf.lock().expect("audio_buffer lock");
        read_audio_from_buffer(&mut jb, requested_frames, frames_played_since_last_read)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rdp_core::AudioStreamFormat;
    use tokio::sync::Notify;

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

    #[test]
    fn ffi_connect_config_maps_fields_and_defaults_client_name() {
        let ffi_cfg = FfiConnectConfig {
            host: "192.168.1.10".into(),
            port: 3390,
            width: 1280,
            height: 720,
            scale_factor: 150,
            security_mode: FfiSecurityMode::Nla,
            audio_mode: FfiAudioMode::Local,
            client_name: "   ".into(),
            pinned_cert_sha256: Some("abcd".into()),
            enable_server_pointer: true,
            pointer_software_rendering: false,
        };
        let core_cfg = ffi_cfg.to_core_config();
        assert_eq!(core_cfg.host, "192.168.1.10");
        assert_eq!(core_cfg.port, 3390);
        assert_eq!(core_cfg.width, 1280);
        assert_eq!(core_cfg.height, 720);
        assert_eq!(core_cfg.scale_factor, 150);
        assert_eq!(core_cfg.security_mode, SecurityMode::Nla);
        assert_eq!(core_cfg.audio_mode, AudioMode::Local);
        assert_eq!(core_cfg.client_name, "aer-rdp");
        assert_eq!(core_cfg.pinned_cert_sha256.as_deref(), Some("abcd"));
    }

    #[test]
    fn ffi_tokio_runtime_can_spawn_from_sync_thread() {
        let rt = runtime();
        let _guard = rt.enter();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        rt.spawn(async move {
            let _ = tx.send(42u32);
        });
        let val = rt.block_on(rx.recv());
        assert_eq!(val, Some(42));
    }

    #[test]
    fn ffi_dirty_rect_coalescing_and_subrect_extraction() {
        let slot = Mutex::new(None);
        coalesce_dirty_rect(
            &slot,
            DirtyRect {
                x: 2,
                y: 1,
                w: 3,
                h: 2,
            },
        );
        coalesce_dirty_rect(
            &slot,
            DirtyRect {
                x: 4,
                y: 2,
                w: 2,
                h: 2,
            },
        );
        let merged = slot.lock().unwrap().take().unwrap();
        assert_eq!(
            merged,
            DirtyRect {
                x: 2,
                y: 1,
                w: 4,
                h: 3
            }
        );

        let fb_w = 10u16;
        let fb_h = 10u16;
        let mut data = vec![0u8; usize::from(fb_w) * usize::from(fb_h) * 4];
        for y in 0..fb_h {
            for x in 0..fb_w {
                let idx = (usize::from(y) * usize::from(fb_w) + usize::from(x)) * 4;
                data[idx] = x as u8;
                data[idx + 1] = y as u8;
                data[idx + 2] = 0x55;
                data[idx + 3] = 0xFF;
            }
        }

        assert!(extract_frame_patch(fb_w, fb_h, &data, None, false).is_none());

        let patch = extract_frame_patch(fb_w, fb_h, &data, Some(merged), false).unwrap();
        assert!(!patch.is_full_frame);
        assert_eq!((patch.x, patch.y, patch.w, patch.h), (2, 1, 4, 3));
        assert_eq!(patch.rgba_bytes.len(), 4 * 3 * 4);
        assert_eq!(&patch.rgba_bytes[0..4], &[2, 1, 0x55, 0xFF]);

        let full = extract_frame_patch(
            fb_w,
            fb_h,
            &data,
            Some(DirtyRect {
                x: 0,
                y: 0,
                w: 8,
                h: 8,
            }),
            false,
        )
        .unwrap();
        assert!(full.is_full_frame);
        assert_eq!(full.rgba_bytes.len(), data.len());
    }

    #[test]
    fn ffi_read_audio_pcm_tail_credit_avoids_underrun_inflation() {
        let notify = Arc::new(Notify::new());
        let mut jb = AudioJitterBuffer::new(notify);
        jb.set_format(AudioStreamFormat {
            sample_rate: 48_000,
            channels: 2,
            bits_per_sample: 16,
        });
        let block = vec![0x11u8; 960 * 4];
        for i in 0..3u8 {
            jb.push_pcm_block(u16::from(i) * 20, i, &block);
        }

        let r1 = read_audio_from_buffer(&mut jb, 960, 0);
        assert_eq!(r1.frames_read, 960);
        assert_eq!(r1.underruns, 0);

        let r2 = read_audio_from_buffer(&mut jb, 960, 960);
        assert_eq!(r2.frames_read, 960);

        let r3 = read_audio_from_buffer(&mut jb, 960, 960);
        assert_eq!(r3.frames_read, 960);
        assert_eq!(jb.queued_frames(), 0);

        let r_tail = read_audio_from_buffer(&mut jb, 960, 960);
        assert_eq!(r_tail.frames_read, 0);
        assert!(r_tail.pcm_bytes.is_empty());
        assert_eq!(r_tail.underruns, 0);
        assert_eq!(jb.drain_ready_confirms().len(), 3);
    }
}
