use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use ironrdp::pdu::rdp::server_error_info::ErrorInfo;
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, oneshot};
use tokio::task::JoinHandle;

pub mod cert;
pub mod credssp;
pub mod display;
pub mod http_control;
pub mod rdpsnd;
pub mod rle16_24;
pub mod server;

// M1 bootstrap exports preserved for compatibility
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthMode {
    Auto,
    Nla,
    Tls,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelEncoding {
    Raw32,
    Rdp6Rle32,
    Raw24,
    Rle24,
    Raw16,
    Rle16,
}

#[derive(Debug, Clone)]
pub enum PointerTestUpdate {
    Rgba {
        cache_index: u16,
        width: u16,
        height: u16,
        hot_x: u16,
        hot_y: u16,
        rgba: Vec<u8>,
    },
    Color {
        cache_index: u16,
        width: u16,
        height: u16,
        hot_x: u16,
        hot_y: u16,
        xor_mask: Vec<u8>,
        and_mask: Vec<u8>,
    },
    Position {
        x: u16,
        y: u16,
    },
    Cached(u16),
    Hidden,
    Default,
}

#[derive(Debug, Clone)]
pub struct MockConfig {
    pub bind_addr: SocketAddr,
    pub auth_mode: AuthMode,
    pub username: String,
    pub password: String,
    pub domain: String,
    pub desktop_width: u16,
    pub desktop_height: u16,
    pub pixel_encoding: PixelEncoding,
    pub audio_hz: u32,
    pub audio_sample_rate: u32,
    pub audio_channels: u16,
    pub audio_chunk_ms: u32,
    pub auto_audio_interval_ms: Option<u64>,
    pub rdpsnd_version: u16,
    pub control_http_addr: Option<SocketAddr>,
    pub cert_seed: Option<[u8; 32]>,
    pub honor_client_desktop_size: bool,
    pub emit_initial_pointer: bool,
}

impl Default for MockConfig {
    fn default() -> Self {
        Self {
            bind_addr: ([127, 0, 0, 1], 0).into(),
            auth_mode: AuthMode::Auto,
            username: "testuser".to_owned(),
            password: "testpass".to_owned(),
            domain: String::new(),
            desktop_width: 1280,
            desktop_height: 720,
            pixel_encoding: PixelEncoding::Rdp6Rle32,
            audio_hz: 440,
            audio_sample_rate: 48_000,
            audio_channels: 2,
            audio_chunk_ms: 20,
            auto_audio_interval_ms: Some(20),
            rdpsnd_version: 8,
            control_http_addr: None,
            cert_seed: None,
            honor_client_desktop_size: false,
            emit_initial_pointer: false,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MockMetrics {
    pub frames_sent: u64,
    pub audio_blocks_sent: u64,
    pub audio_blocks_confirmed: u64,
    pub last_confirm_latency_ms: Option<u64>,
    pub last_training_rtt_ms: Option<u64>,
    pub in_flight_window: u64,
    pub active_sessions: u64,
    pub total_connections: u64,
    pub auth_failures: u64,
    pub reactivations: u64,
    pub last_disconnect_reason: Option<String>,
    pub last_audio_timestamp_ms: Option<u32>,
    pub last_frame_timestamp_ms: Option<u32>,
}

pub type ServerMetricsInner = MockMetrics;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RecordedInput {
    Pointer {
        x: u16,
        y: u16,
        button_mask: u8,
        action: String,
        wheel_delta: i16,
        timestamp_ms: u64,
    },
    Scancode {
        code: u8,
        extended: bool,
        down: bool,
        timestamp_ms: u64,
    },
    Unicode {
        code_unit: u16,
        down: bool,
        timestamp_ms: u64,
    },
}

#[derive(Clone)]
pub enum ControlCmd {
    DeactivateAll {
        new_size: Option<(u16, u16)>,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<()>>>>>,
    },
    Disconnect {
        error_info: ErrorInfo,
    },
    SocketDrop,
    Frame {
        encoding_override: Option<PixelEncoding>,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<u64>>>>>,
    },
    SlowPathFrame {
        encoding_override: Option<PixelEncoding>,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<u64>>>>>,
    },
    AudioBurst {
        blocks: usize,
        interval_ms: u64,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<()>>>>>,
    },
    RdpsndTraining {
        payload_len: usize,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<()>>>>>,
    },
    RdpsndVolume {
        left: u16,
        right: u16,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<()>>>>>,
    },
    PointerUpdate {
        kind: PointerTestUpdate,
        ack: Option<Arc<Mutex<Option<oneshot::Sender<()>>>>>,
    },
}

pub struct ShutdownHandle {
    rdp_shutdown: Option<oneshot::Sender<()>>,
    http_shutdown: Option<oneshot::Sender<()>>,
    rdp_task: Option<JoinHandle<()>>,
    http_task: Option<JoinHandle<()>>,
}

impl ShutdownHandle {
    pub async fn shutdown(mut self) {
        if let Some(tx) = self.rdp_shutdown.take() {
            let _ = tx.send(());
        }
        if let Some(tx) = self.http_shutdown.take() {
            let _ = tx.send(());
        }
        if let Some(t) = self.rdp_task.take() {
            let _ = t.await;
        }
        if let Some(t) = self.http_task.take() {
            let _ = t.await;
        }
    }
}

pub struct MockRdpServer {
    pub port: u16,
    pub http_port: Option<u16>,
    pub cert_sha256: String,
    pub cert_der: Vec<u8>,
    pub shutdown_handle: Option<ShutdownHandle>,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    control_tx: broadcast::Sender<ControlCmd>,
}

impl MockRdpServer {
    pub async fn start(config: MockConfig) -> anyhow::Result<Self> {
        let identity = cert::get_or_create_identity(config.cert_seed)?;
        let rdp_listener = TcpListener::bind(config.bind_addr).await?;
        let rdp_port = rdp_listener.local_addr()?.port();

        let metrics = Arc::new(Mutex::new(ServerMetricsInner::default()));
        let recorded_inputs = Arc::new(Mutex::new(Vec::new()));
        let (control_tx, _) = broadcast::channel(64);
        let (rdp_sd_tx, rdp_sd_rx) = oneshot::channel();

        let rdp_task = tokio::spawn(server::run_rdp_accept_loop(
            rdp_listener,
            config.clone(),
            Arc::clone(&identity),
            Arc::clone(&metrics),
            Arc::clone(&recorded_inputs),
            control_tx.clone(),
            rdp_sd_rx,
        ));

        let (http_port, http_sd_tx, http_task) = if let Some(http_addr) = config.control_http_addr {
            let http_listener = TcpListener::bind(http_addr).await?;
            let port = http_listener.local_addr()?.port();
            let (sd_tx, sd_rx) = oneshot::channel();
            let task = tokio::spawn(http_control::run_http_server(
                http_listener,
                rdp_port,
                identity.cert_sha256.clone(),
                Arc::clone(&metrics),
                Arc::clone(&recorded_inputs),
                control_tx.clone(),
                sd_rx,
            ));
            (Some(port), Some(sd_tx), Some(task))
        } else {
            (None, None, None)
        };

        Ok(Self {
            port: rdp_port,
            http_port,
            cert_sha256: identity.cert_sha256.clone(),
            cert_der: identity.cert_der.clone(),
            shutdown_handle: Some(ShutdownHandle {
                rdp_shutdown: Some(rdp_sd_tx),
                http_shutdown: http_sd_tx,
                rdp_task: Some(rdp_task),
                http_task,
            }),
            metrics,
            recorded_inputs,
            control_tx,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn cert_sha256(&self) -> &str {
        &self.cert_sha256
    }

    pub fn metrics(&self) -> MockMetrics {
        self.metrics.lock().expect("metrics lock").clone()
    }

    pub fn recorded_inputs(&self) -> Vec<RecordedInput> {
        self.recorded_inputs.lock().expect("inputs lock").clone()
    }

    pub fn clear_recorded_inputs(&self) {
        self.recorded_inputs.lock().expect("inputs lock").clear();
    }

    pub async fn trigger_deactivate_all(&self, new_size: Option<(u16, u16)>) -> anyhow::Result<()> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::DeactivateAll {
            new_size,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), rx).await;
        Ok(())
    }

    pub async fn trigger_disconnect(&self, error_info: ErrorInfo) -> anyhow::Result<()> {
        let _ = self.control_tx.send(ControlCmd::Disconnect { error_info });
        Ok(())
    }

    pub async fn trigger_socket_drop(&self) -> anyhow::Result<()> {
        let _ = self.control_tx.send(ControlCmd::SocketDrop);
        Ok(())
    }

    pub async fn trigger_frame(&self, encoding_override: Option<PixelEncoding>) -> anyhow::Result<u64> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::Frame {
            encoding_override,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let count = tokio::time::timeout(std::time::Duration::from_secs(3), rx)
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_else(|| self.metrics().frames_sent);
        Ok(count)
    }

    pub async fn trigger_slowpath_frame(&self, encoding_override: Option<PixelEncoding>) -> anyhow::Result<u64> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::SlowPathFrame {
            encoding_override,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let count = tokio::time::timeout(std::time::Duration::from_secs(3), rx)
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_else(|| self.metrics().frames_sent);
        Ok(count)
    }

    pub async fn trigger_audio_burst(&self, blocks: usize, interval_ms: u64) -> anyhow::Result<()> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::AudioBurst {
            blocks,
            interval_ms,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), rx).await;
        Ok(())
    }

    pub async fn trigger_rdpsnd_training(&self, payload_len: usize) -> anyhow::Result<()> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::RdpsndTraining {
            payload_len,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), rx).await;
        Ok(())
    }

    pub async fn trigger_rdpsnd_volume(&self, left: u16, right: u16) -> anyhow::Result<()> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::RdpsndVolume {
            left,
            right,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), rx).await;
        Ok(())
    }

    pub async fn trigger_pointer_update(&self, kind: PointerTestUpdate) -> anyhow::Result<()> {
        let (tx, rx) = oneshot::channel();
        let _ = self.control_tx.send(ControlCmd::PointerUpdate {
            kind,
            ack: Some(Arc::new(Mutex::new(Some(tx)))),
        });
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), rx).await;
        Ok(())
    }

    pub async fn shutdown(mut self) {
        if let Some(handle) = self.shutdown_handle.take() {
            handle.shutdown().await;
        }
    }
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
