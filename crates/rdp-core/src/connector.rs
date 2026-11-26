use std::sync::{Arc, Mutex};

use ironrdp::connector::connection_activation::ConnectionActivationState;
use ironrdp::connector::{
    BitmapConfig, ClientConnector, ClientConnectorState, Config as ConnectorConfig, ConnectionResult,
    ConnectorErrorKind, Credentials, DesktopSize, Sequence as _, ServerName, state_downcast,
};
use ironrdp::pdu::nego::FailureCode;
use ironrdp::pdu::rdp::capability_sets::{BitmapCodecs, MajorPlatformType};
use ironrdp::pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp_tokio::{
    NetworkClient, TokioFramed, connect_begin, connect_finalize, mark_as_upgraded,
    single_sequence_step,
};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::audio::AudioJitterBuffer;
use crate::rdpsnd::AerRdpsndProcessor;
use crate::tls;
use crate::types::{
    AuthCredentials, AudioMode, CertInfo, CertTrustDecision, ConnectConfig, CoreError, SecurityMode,
    SessionCommand, SessionEvent, SessionState, normalize_sha256_pin,
};

struct NoopNetworkClient;

impl NetworkClient for NoopNetworkClient {
    async fn send(&mut self, _request: &ironrdp::connector::sspi::NetworkRequest) -> ironrdp::connector::ConnectorResult<Vec<u8>> {
        Err(ironrdp::connector::general_err!("kerberos KDC proxy not supported"))
    }
}

pub struct ConnectedSession {
    pub framed: TokioFramed<ironrdp_tls::TlsStream<TcpStream>>,
    pub connection_result: ConnectionResult,
    pub cert_info: CertInfo,
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

    ConnectorConfig {
        desktop_size: DesktopSize {
            width: aligned_w,
            height: clamped_h,
        },
        desktop_scale_factor: config.scale_factor,
        enable_tls,
        enable_credssp,
        credentials: Credentials::UsernamePassword { username, password },
        domain,
        client_build: 0,
        client_name: config.client_name.chars().take(15).collect(),
        keyboard_type: ironrdp::pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0x0409,
        ime_file_name: String::new(),
        bitmap: Some(BitmapConfig {
            lossy_compression: false,
            color_depth: 32,
            codecs: BitmapCodecs(Vec::new()),
        }),
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: MajorPlatformType::WINDOWS,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: matches!(config.audio_mode, AudioMode::Local),
        performance_flags: PerformanceFlags::default(),
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: config.enable_server_pointer,
        pointer_software_rendering: config.pointer_software_rendering,
        multitransport_flags: None,
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
        let mut connector = ClientConnector::new(connector_cfg, client_addr);
        if matches!(config.audio_mode, AudioMode::Local) {
            connector = connector.with_static_channel(AerRdpsndProcessor::new(
                Arc::clone(&jitter_buffer),
                event_tx.clone(),
            ));
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
                    ironrdp::pdu::nego::SecurityProtocol::HYBRID
                        | ironrdp::pdu::nego::SecurityProtocol::HYBRID_EX
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
    activation_factory: &mut ironrdp::connector::connection_activation::ConnectionActivationFactory,
) -> Result<(u16, u16, u32), CoreError> {
    let mut seq = activation_factory.create();
    let mut write_buf = ironrdp::core::WriteBuf::new();

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
