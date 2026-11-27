use std::sync::{Arc, Mutex};

use ironrdp_connector::connection_activation::ConnectionActivationState;
use ironrdp_connector::{
    BitmapConfig, ClientConnector, ClientConnectorState, Config as ConnectorConfig,
    ConnectionResult, ConnectorErrorKind, Credentials, DesktopSize, Sequence as _, ServerName,
    state_downcast,
};
use ironrdp_displaycontrol::client::DisplayControlClient;
use ironrdp_dvc::DrdynvcClient;
use ironrdp_echo::client::EchoClient;
use ironrdp_egfx::client::{GraphicsPipelineClient, GraphicsPipelineHandler};
use ironrdp_egfx::decode::{H264Decoder, OpenH264Decoder};
use ironrdp_egfx::pdu::{
    CapabilitiesV8Flags, CapabilitiesV81Flags, CapabilitySet as EgfxCapabilitySet,
};
use ironrdp_pdu::gcc::{ConnectionType, KeyboardType};
use ironrdp_pdu::nego::{FailureCode, SecurityProtocol};
use ironrdp_pdu::rdp::capability_sets::{
    BitmapCodecs, MajorPlatformType, RailSupportLevel, client_codecs_capabilities,
};
use ironrdp_pdu::rdp::client_info::{CompressionType, PerformanceFlags, TimezoneInfo};
use ironrdp_tokio::{
    NetworkClient, TokioFramed, connect_begin, connect_finalize, mark_as_upgraded,
    single_sequence_step,
};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::audio::AudioJitterBuffer;
use crate::rdpsnd::{AerRdpsndCore, AerRdpsndProcessor};
use crate::tls;
use crate::types::{
    AudioMode, AuthCredentials, BandwidthMode, CertInfo, CertTrustDecision, ConnectConfig,
    CoreError, SecurityMode, SessionCommand, SessionEvent, SessionState, normalize_sha256_pin,
};

struct NoopNetworkClient;

impl NetworkClient for NoopNetworkClient {
    async fn send(
        &mut self,
        _request: &ironrdp_connector::sspi::NetworkRequest,
    ) -> ironrdp_connector::ConnectorResult<Vec<u8>> {
        Err(ironrdp_connector::general_err!("kerberos KDC proxy not supported"))
    }
}

struct AerEgfxHandler {
    bandwidth_mode: BandwidthMode,
}

impl GraphicsPipelineHandler for AerEgfxHandler {
    fn capabilities(&self) -> Vec<EgfxCapabilitySet> {
        match self.bandwidth_mode {
            // HighQuality advertises full V10.7..V8 (AVC444 4:4:4 chroma + AVC420 + Progressive).
            BandwidthMode::HighQuality => {
                struct DefaultCaps;
                impl GraphicsPipelineHandler for DefaultCaps {}
                DefaultCaps.capabilities()
            }
            // Balanced & LowBandwidth advertise single-stream H.264 AVC420 (V8.1) + V8 fallback,
            // halving mobile H.264 decode work & bitrate at high-DPI phone resolutions.
            BandwidthMode::Balanced | BandwidthMode::LowBandwidth => vec![
                EgfxCapabilitySet::V8_1 {
                    flags: CapabilitiesV81Flags::AVC420_ENABLED | CapabilitiesV81Flags::SMALL_CACHE,
                },
                EgfxCapabilitySet::V8 {
                    flags: CapabilitiesV8Flags::SMALL_CACHE,
                },
            ],
        }
    }
}

fn create_openh264_decoder() -> Option<Box<dyn H264Decoder>> {
    match OpenH264Decoder::new() {
        Ok(dec) => Some(Box::new(dec)),
        Err(err) => {
            warn!(error = %err, "failed to initialize bundled OpenH264 decoder");
            None
        }
    }
}

pub fn build_egfx_client(bandwidth_mode: BandwidthMode) -> GraphicsPipelineClient {
    GraphicsPipelineClient::new(
        Box::new(AerEgfxHandler { bandwidth_mode }),
        create_openh264_decoder(),
    )
}

fn build_session_drdynvc(bandwidth_mode: BandwidthMode) -> DrdynvcClient {
    DrdynvcClient::new()
        .with_dynamic_channel(build_egfx_client(bandwidth_mode))
        .with_dynamic_channel(DisplayControlClient::new(|_| Ok(Vec::new())))
        .with_dynamic_channel(EchoClient::new())
}

pub struct ConnectedSession {
    pub framed: TokioFramed<ironrdp_tls::TlsStream<TcpStream>>,
    pub connection_result: ConnectionResult,
    pub cert_info: CertInfo,
    pub rdpsnd_core: Option<Arc<Mutex<AerRdpsndCore>>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AttemptSecurity {
    Both,
    NlaOnly,
    TlsOnly,
}

impl AttemptSecurity {
    fn from_mode(mode: SecurityMode) -> Self {
        match mode {
            SecurityMode::Auto => Self::Both,
            SecurityMode::Nla => Self::NlaOnly,
            SecurityMode::Tls => Self::TlsOnly,
        }
    }

    fn flags(self) -> (bool, bool) {
        match self {
            Self::Both => (true, true),
            Self::NlaOnly => (false, true),
            Self::TlsOnly => (true, false),
        }
    }
}

fn build_connector_config(
    config: &ConnectConfig,
    creds: &Option<AuthCredentials>,
    attempt_sec: AttemptSecurity,
) -> ConnectorConfig {
    let (aligned_w, clamped_h) = config.aligned_dimensions();
    let (enable_tls, enable_credssp) = attempt_sec.flags();

    let (username, password, domain) = match creds {
        Some(c) => (
            c.username.clone(),
            c.password.clone(),
            c.domain.clone().filter(|d| !d.is_empty()),
        ),
        None => (String::new(), String::new(), None),
    };

    let (color_depth, lossy_compression, connection_type, performance_flags) =
        match config.bandwidth_mode {
            BandwidthMode::HighQuality => (
                32,
                true,
                ConnectionType::Lan,
                PerformanceFlags::ENABLE_FONT_SMOOTHING
                    | PerformanceFlags::ENABLE_DESKTOP_COMPOSITION
                    | PerformanceFlags::DISABLE_MENUANIMATIONS,
            ),
            BandwidthMode::Balanced => (
                32,
                true,
                ConnectionType::Lan,
                PerformanceFlags::ENABLE_FONT_SMOOTHING | PerformanceFlags::DISABLE_MENUANIMATIONS,
            ),
            BandwidthMode::LowBandwidth => (
                16,
                true,
                ConnectionType::BroadbandLow,
                PerformanceFlags::DISABLE_WALLPAPER
                    | PerformanceFlags::DISABLE_FULLWINDOWDRAG
                    | PerformanceFlags::DISABLE_MENUANIMATIONS
                    | PerformanceFlags::DISABLE_THEMING
                    | PerformanceFlags::DISABLE_CURSOR_SHADOW
                    | PerformanceFlags::DISABLE_CURSORSETTINGS,
            ),
        };

    let codecs = client_codecs_capabilities(&[]).unwrap_or_else(|_| BitmapCodecs(Vec::new()));

    ConnectorConfig {
        desktop_size: DesktopSize {
            width: aligned_w,
            height: clamped_h,
        },
        monitor_layout: None,
        desktop_scale_factor: config.scale_factor,
        desktop_physical_size: None,
        desktop_orientation: None,
        device_scale_factor: None,
        monitor_extended_layout: None,
        relative_mouse_input: false,
        enable_tls,
        enable_credssp,
        enable_standard_rdp_security: false,
        credentials: Credentials::UsernamePassword { username, password },
        domain,
        client_build: 2600,
        client_name: config.client_name.chars().take(15).collect(),
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0x0409,
        connection_type,
        ime_file_name: String::new(),
        bitmap: Some(BitmapConfig {
            lossy_compression,
            color_depth,
            codecs,
        }),
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: RailSupportLevel::empty(),
        platform: MajorPlatformType::WINDOWS,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: matches!(config.audio_mode, AudioMode::Local),
        enable_audio_capture: false,
        performance_flags,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: Some(CompressionType::K64),
        enable_server_pointer: config.enable_server_pointer,
        pointer_software_rendering: config.pointer_software_rendering,
        multitransport_flags: None,
        support_dyn_vc_gfx_protocol: true,
    }
}

async fn wait_for_cert_decision(
    cmd_rx: &mut mpsc::UnboundedReceiver<SessionCommand>,
) -> Result<CertTrustDecision, CoreError> {
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            SessionCommand::SubmitCertDecision(d) => return Ok(d),
            SessionCommand::Disconnect => return Err(CoreError::Cancelled),
            _ => {}
        }
    }
    Err(CoreError::ChannelClosed)
}

async fn wait_for_credentials(
    cmd_rx: &mut mpsc::UnboundedReceiver<SessionCommand>,
) -> Result<AuthCredentials, CoreError> {
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            SessionCommand::SubmitCredentials(creds) => return Ok(creds),
            SessionCommand::Disconnect => return Err(CoreError::Cancelled),
            _ => {}
        }
    }
    Err(CoreError::ChannelClosed)
}

pub async fn connect_and_activate(
    config: &ConnectConfig,
    initial_creds: Option<AuthCredentials>,
    jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
    event_tx: &mpsc::UnboundedSender<SessionEvent>,
    cmd_rx: &mut mpsc::UnboundedReceiver<SessionCommand>,
) -> Result<ConnectedSession, CoreError> {
    config.validate()?;

    let mut current_creds = initial_creds;
    let mut attempt_sec = AttemptSecurity::from_mode(config.security_mode);
    let mut trusted_sha256_in_session: Option<String> = None;
    let mut auth_attempts: u32 = 0;
    let mut security_fallback_used = false;

    loop {
        let addr_str = format!("{}:{}", config.host, config.port);
        let tcp_stream = TcpStream::connect(&addr_str).await?;
        let _ = tcp_stream.set_nodelay(true);
        let client_addr = tcp_stream.local_addr()?;

        let connector_cfg = build_connector_config(config, &current_creds, attempt_sec);
        let rdpdr_client_name = connector_cfg.client_name.clone();
        let mut connector = ClientConnector::new(connector_cfg, client_addr);
        let drdynvc = build_session_drdynvc(config.bandwidth_mode);
        let mut rdpsnd_core_handle = None;
        if matches!(config.audio_mode, AudioMode::Local) {
            let (svc, drdynvc, core) = AerRdpsndProcessor::attach_to_drdynvc(
                drdynvc,
                Arc::clone(&jitter_buffer),
                event_tx.clone(),
            );
            let rdpdr = ironrdp_rdpdr::Rdpdr::new(
                Box::new(ironrdp_rdpdr::NoopRdpdrBackend),
                rdpdr_client_name,
            );
            rdpsnd_core_handle = Some(core);
            connector = connector
                .with_static_channel(svc)
                .with_static_channel(drdynvc)
                .with_static_channel(rdpdr);
        } else {
            connector = connector.with_static_channel(drdynvc);
        }

        let mut framed = TokioFramed::new(tcp_stream);
        let should_upgrade = match connect_begin(&mut framed, &mut connector).await {
            Ok(token) => token,
            Err(err) => {
                if config.security_mode == SecurityMode::Auto
                    && !security_fallback_used
                    && let ConnectorErrorKind::Negotiation(neg) = err.kind()
                {
                    match neg.code() {
                        FailureCode::SSL_REQUIRED_BY_SERVER
                        | FailureCode::SSL_CERT_NOT_ON_SERVER => {
                            warn!(?neg, "Auto mode falling back to TlsOnly");
                            attempt_sec = AttemptSecurity::TlsOnly;
                            security_fallback_used = true;
                            continue;
                        }
                        FailureCode::HYBRID_REQUIRED_BY_SERVER => {
                            warn!(?neg, "Auto mode falling back to NlaOnly");
                            attempt_sec = AttemptSecurity::NlaOnly;
                            security_fallback_used = true;
                            continue;
                        }
                        _ => {}
                    }
                }
                return Err(CoreError::Connector(err.to_string()));
            }
        };

        let (tcp_stream, leftover) = framed.into_inner();
        if !leftover.is_empty() {
            debug!(leftover_len = leftover.len(), "unexpected leftover bytes before TLS upgrade");
        }

        let (mut tls_stream, cert_info, server_public_key) =
            tls::connect_and_inspect(tcp_stream, &config.host).await?;

        // Certificate verification / pinning BEFORE CredSSP / MCS.
        if let Some(pin) = &config.pinned_cert_sha256 {
            let expected = normalize_sha256_pin(pin);
            if cert_info.sha256_hex != expected {
                let _ = tls_stream.shutdown().await;
                return Err(CoreError::CertMismatch {
                    expected,
                    actual: cert_info.sha256_hex.clone(),
                    cert_info: Box::new(cert_info),
                });
            }
        } else if trusted_sha256_in_session.as_deref() != Some(&cert_info.sha256_hex) {
            let _ = event_tx.send(SessionEvent::SessionStateChanged(SessionState::CertPrompt(
                cert_info.clone(),
            )));
            match wait_for_cert_decision(cmd_rx).await {
                Ok(CertTrustDecision::TrustOnce | CertTrustDecision::TrustAlways) => {
                    trusted_sha256_in_session = Some(cert_info.sha256_hex.clone());
                }
                Ok(CertTrustDecision::Reject) => {
                    let _ = tls_stream.shutdown().await;
                    return Err(CoreError::CertRejected);
                }
                Err(e) => {
                    let _ = tls_stream.shutdown().await;
                    return Err(e);
                }
            }
        }

        let will_do_credssp = matches!(
            connector.state,
            ClientConnectorState::EnhancedSecurityUpgrade { selected_protocol }
                if selected_protocol.intersects(
                    SecurityProtocol::HYBRID | SecurityProtocol::HYBRID_EX
                )
        );

        // Check if CredSSP needs credentials before finalizing.
        if will_do_credssp {
            let needs_prompt = match &current_creds {
                None => true,
                Some(c) => c.username.is_empty(),
            };
            if needs_prompt {
                let _ = event_tx.send(SessionEvent::SessionStateChanged(SessionState::AuthPrompt {
                    reason: None,
                }));
                match wait_for_credentials(cmd_rx).await {
                    Ok(new_creds) => {
                        connector.config.credentials = Credentials::UsernamePassword {
                            username: new_creds.username.clone(),
                            password: new_creds.password.clone(),
                        };
                        connector.config.domain = new_creds.domain.clone().filter(|d| !d.is_empty());
                        current_creds = Some(new_creds);
                    }
                    Err(e) => {
                        let _ = tls_stream.shutdown().await;
                        return Err(e);
                    }
                }
            }
        }

        let upgraded = mark_as_upgraded(should_upgrade, &mut connector);

        let mut tls_framed = TokioFramed::new(tls_stream);
        let mut noop_net = NoopNetworkClient;
        let server_name = ServerName::new(config.host.clone());

        match connect_finalize(
            upgraded,
            connector,
            &mut tls_framed,
            &mut noop_net,
            server_name,
            server_public_key,
            None,
        )
        .await
        .and_then(|outcome| outcome.into_connected())
        {
            Ok(connection_result) => {
                info!(
                    width = connection_result.desktop_size.width,
                    height = connection_result.desktop_size.height,
                    "RDP connection finalized"
                );
                return Ok(ConnectedSession {
                    framed: tls_framed,
                    connection_result,
                    cert_info,
                    rdpsnd_core: rdpsnd_core_handle,
                });
            }
            Err(err) => {
                let is_auth_err = matches!(
                    err.kind(),
                    ConnectorErrorKind::AccessDenied | ConnectorErrorKind::Credssp(_)
                );
                if is_auth_err {
                    auth_attempts += 1;
                    let (mut stream, _) = tls_framed.into_inner();
                    let _ = stream.shutdown().await;

                    if auth_attempts > 5 {
                        return Err(CoreError::AuthFailed(err.to_string()));
                    }

                    let _ = event_tx.send(SessionEvent::SessionStateChanged(SessionState::AuthPrompt {
                        reason: Some(err.to_string()),
                    }));
                    let new_creds = wait_for_credentials(cmd_rx).await?;
                    current_creds = Some(new_creds);
                    continue;
                }

                // Handle Negotiation failure code if any occurred late
                if let ConnectorErrorKind::Negotiation(neg) = err.kind()
                    && neg.code() == FailureCode::SSL_REQUIRED_BY_SERVER
                    && config.security_mode == SecurityMode::Auto
                    && !security_fallback_used
                {
                    attempt_sec = AttemptSecurity::TlsOnly;
                    security_fallback_used = true;
                    continue;
                }

                return Err(CoreError::Connector(err.to_string()));
            }
        }
    }
}

pub async fn run_deactivation_reactivation(
    framed: &mut TokioFramed<ironrdp_tls::TlsStream<TcpStream>>,
    activation_factory: &mut ironrdp_connector::connection_activation::ConnectionActivationFactory,
) -> Result<(u16, u16, u32), CoreError> {
    let mut seq = activation_factory.create();
    let mut write_buf = ironrdp_core::WriteBuf::new();

    loop {
        if let Some(ConnectionActivationState::Finalized {
            desktop_size,
            share_id,
            ..
        }) = state_downcast::<ConnectionActivationState>(seq.state())
        {
            return Ok((desktop_size.width, desktop_size.height, *share_id));
        }

        single_sequence_step(framed, &mut seq, &mut write_buf)
            .await
            .map_err(|e| CoreError::Session(format!("reactivation failed: {e}")))?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_pdu::gcc::ChannelName;
    use std::net::SocketAddr;
    use tokio::sync::Notify;

    #[test]
    fn connector_config_enables_egfx_rdp10_h264_and_bandwidth_modes() {
        assert!(OpenH264Decoder::new().is_ok(), "bundled OpenH264 decoder must initialize");

        let base = ConnectConfig {
            host: "10.0.0.1".to_owned(),
            bandwidth_mode: BandwidthMode::Balanced,
            ..Default::default()
        };
        let cfg_bal = build_connector_config(&base, &None, AttemptSecurity::Both);
        assert_eq!(cfg_bal.client_build, 2600);
        assert!(cfg_bal.support_dyn_vc_gfx_protocol, "MS-RDPEGFX DVC flag must be enabled");
        assert_eq!(cfg_bal.connection_type, ConnectionType::Lan);
        assert_eq!(cfg_bal.compression_type, Some(CompressionType::K64));
        let bmp_bal = cfg_bal.bitmap.expect("bitmap config");
        assert_eq!(bmp_bal.color_depth, 32);
        assert!(bmp_bal.lossy_compression);
        assert!(!bmp_bal.codecs.0.is_empty(), "RemoteFX fallback codecs must be enabled");

        let cfg_hq = build_connector_config(
            &ConnectConfig {
                bandwidth_mode: BandwidthMode::HighQuality,
                ..base.clone()
            },
            &None,
            AttemptSecurity::Both,
        );
        let bmp_hq = cfg_hq.bitmap.expect("bitmap config");
        assert_eq!(bmp_hq.color_depth, 32);
        assert!(bmp_hq.lossy_compression);
        assert_eq!(cfg_hq.connection_type, ConnectionType::Lan);
        assert!(
            cfg_hq
                .performance_flags
                .contains(PerformanceFlags::ENABLE_DESKTOP_COMPOSITION)
        );
        let hq_caps = AerEgfxHandler {
            bandwidth_mode: BandwidthMode::HighQuality,
        }
        .capabilities();
        assert!(
            hq_caps.iter().any(|c| matches!(c, EgfxCapabilitySet::V10_7 { .. })),
            "HighQuality must advertise V10_7 AVC444 capability"
        );

        let bal_caps = AerEgfxHandler {
            bandwidth_mode: BandwidthMode::Balanced,
        }
        .capabilities();
        assert!(
            bal_caps.iter().any(|c| matches!(c, EgfxCapabilitySet::V8_1 { .. }))
                && !bal_caps.iter().any(|c| matches!(c, EgfxCapabilitySet::V10_7 { .. })),
            "Balanced must advertise single-stream AVC420 V8_1 capability"
        );

        let cfg_low = build_connector_config(
            &ConnectConfig {
                bandwidth_mode: BandwidthMode::LowBandwidth,
                ..base
            },
            &None,
            AttemptSecurity::Both,
        );
        let bmp_low = cfg_low.bitmap.expect("bitmap config");
        assert_eq!(bmp_low.color_depth, 16);
        assert!(bmp_low.lossy_compression);
        assert_eq!(cfg_low.connection_type, ConnectionType::BroadbandLow);
        assert!(
            cfg_low
                .performance_flags
                .contains(PerformanceFlags::DISABLE_WALLPAPER)
        );
    }

    #[test]
    fn drdynvc_egfx_is_registered_in_all_audio_modes_and_audio_channels_in_local_mode() {
        let cfg_off = ConnectConfig {
            host: "10.0.0.1".to_owned(),
            audio_mode: AudioMode::Off,
            ..Default::default()
        };
        let conn_off_cfg = build_connector_config(&cfg_off, &None, AttemptSecurity::Both);
        assert!(!conn_off_cfg.enable_audio_playback);
        let conn_off = ClientConnector::new(conn_off_cfg, SocketAddr::from(([127, 0, 0, 1], 0)))
            .with_static_channel(build_session_drdynvc(cfg_off.bandwidth_mode));
        assert!(
            conn_off
                .static_channels
                .get_by_channel_name(&ChannelName::from_static(b"drdynvc\0"))
                .is_some(),
            "drdynvc must be attached even when audio is Off so MS-RDPEGFX works"
        );

        let cfg = ConnectConfig {
            host: "10.0.0.1".to_owned(),
            audio_mode: AudioMode::Local,
            ..Default::default()
        };
        let conn_cfg = build_connector_config(&cfg, &None, AttemptSecurity::Both);
        assert!(conn_cfg.enable_audio_playback);
        let client_name = conn_cfg.client_name.clone();
        let notify = Arc::new(Notify::new());
        let jb = Arc::new(Mutex::new(AudioJitterBuffer::new(notify)));
        let (event_tx, _event_rx) = mpsc::unbounded_channel();
        let drdynvc = build_session_drdynvc(cfg.bandwidth_mode);
        let (svc, drdynvc, _core) = AerRdpsndProcessor::attach_to_drdynvc(drdynvc, jb, event_tx);
        let rdpdr = ironrdp_rdpdr::Rdpdr::new(
            Box::new(ironrdp_rdpdr::NoopRdpdrBackend),
            client_name,
        );
        let connector = ClientConnector::new(conn_cfg, SocketAddr::from(([127, 0, 0, 1], 0)))
            .with_static_channel(svc)
            .with_static_channel(drdynvc)
            .with_static_channel(rdpdr);

        assert!(
            connector
                .static_channels
                .get_by_channel_name(&ChannelName::from_static(b"rdpsnd\0\0"))
                .is_some()
        );
        assert!(
            connector
                .static_channels
                .get_by_channel_name(&ChannelName::from_static(b"drdynvc\0"))
                .is_some()
        );
        assert!(
            connector
                .static_channels
                .get_by_channel_name(&ChannelName::from_static(b"rdpdr\0\0\0"))
                .is_some()
        );
    }
}
