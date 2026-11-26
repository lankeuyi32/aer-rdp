use std::borrow::Cow;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ironrdp::connector::ServerName;
use ironrdp::core::{decode, encode_vec};
use ironrdp::pdu::Action;
use ironrdp::pdu::input::InputEvent;
use ironrdp::pdu::input::fast_path::{FastPathInput, FastPathInputEvent, KeyboardFlags};
use ironrdp::pdu::input::mouse::PointerFlags;
use ironrdp::pdu::input::mouse_x::PointerXFlags;
use ironrdp::pdu::mcs::{DisconnectProviderUltimatum, DisconnectReason, McsMessage, SendDataIndication};
use ironrdp::pdu::nego::SecurityProtocol;
use ironrdp::pdu::rdp::capability_sets::{
    Bitmap, BitmapCodecs, BitmapDrawingFlags, CapabilitySet, CmdFlags, General,
    GeneralExtraFlags, Input, InputFlags, MultifragmentUpdate, Order, OrderFlags,
    OrderSupportExFlags, Pointer, Sound, SoundFlags, SurfaceCommands, VirtualChannel,
    VirtualChannelFlags,
};
use ironrdp::pdu::rdp::headers::{
    ShareControlHeader, ShareControlPdu, ShareDataHeader, ShareDataPdu, StreamPriority,
};
use ironrdp::pdu::rdp::server_error_info::{
    ErrorInfo, ProtocolIndependentCode, ServerSetErrorInfoPdu,
};
use ironrdp::pdu::x224::X224;
use ironrdp::svc::server_encode_svc_messages;
use ironrdp_acceptor::{Acceptor, AcceptorResult, BeginResult, DesktopSize, accept_begin, accept_finalize};
use ironrdp_tokio::{FramedWrite as _, TokioFramed};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, oneshot};
use tracing::{debug, warn};

use crate::cert::ServerIdentity;
use crate::credssp::{CredsspExpected, run_credssp};
use crate::display::{
    DisplaySceneState, SlowPathTile, encode_pointer_update_fastpath, encode_scene_fastpath_frames,
    encode_scene_region_fastpath_frames, encode_slowpath_bitmap_pdu,
};
use crate::rdpsnd::TestRdpsndProcessor;
use crate::{AuthMode, ControlCmd, MockConfig, PixelEncoding, RecordedInput, ServerMetricsInner};

type AckSlot = Arc<Mutex<Option<oneshot::Sender<()>>>>;
type FrameAckSlot = Arc<Mutex<Option<oneshot::Sender<u64>>>>;
type EncodeSceneTask = tokio::task::JoinHandle<anyhow::Result<(Vec<Vec<u8>>, Option<FrameAckSlot>)>>;
type PendingAudioBurst = (usize, u64, Option<AckSlot>);
type PendingTraining = (usize, Option<AckSlot>);
const AUDIO_GATED_TILE_CHUNK_PDUS: usize = 16;
const FRAME_CHUNK_INTERVAL_MS: u64 = 16;

struct ActiveSessionGuard {
    metrics: Arc<Mutex<ServerMetricsInner>>,
    active: bool,
}

impl ActiveSessionGuard {
    fn acquire(metrics: Arc<Mutex<ServerMetricsInner>>) -> Self {
        if let Ok(mut m) = metrics.lock() {
            m.active_sessions += 1;
        }
        Self {
            metrics,
            active: true,
        }
    }

    fn release(&mut self) {
        if self.active {
            self.active = false;
            if let Ok(mut m) = self.metrics.lock() {
                m.active_sessions = m.active_sessions.saturating_sub(1);
            }
        }
    }
}

impl Drop for ActiveSessionGuard {
    fn drop(&mut self) {
        self.release();
    }
}

pub fn build_server_capabilities(size: DesktopSize) -> Vec<CapabilitySet> {
    vec![
        CapabilitySet::General(General {
            extra_flags: GeneralExtraFlags::FASTPATH_OUTPUT_SUPPORTED,
            refresh_rect_support: true,
            suppress_output_support: true,
            ..Default::default()
        }),
        CapabilitySet::Bitmap(Bitmap {
            pref_bits_per_pix: 32,
            desktop_width: size.width,
            desktop_height: size.height,
            desktop_resize_flag: true,
            drawing_flags: BitmapDrawingFlags::empty(),
        }),
        CapabilitySet::Order(Order::new(
            OrderFlags::empty(),
            OrderSupportExFlags::empty(),
            2048,
            224,
        )),
        CapabilitySet::SurfaceCommands(SurfaceCommands {
            flags: CmdFlags::FRAME_MARKER,
        }),
        CapabilitySet::Pointer(Pointer {
            color_pointer_cache_size: 2048,
            pointer_cache_size: 2048,
        }),
        CapabilitySet::Input(Input {
            input_flags: InputFlags::SCANCODES
                | InputFlags::MOUSE_RELATIVE
                | InputFlags::MOUSEX
                | InputFlags::FASTPATH_INPUT
                | InputFlags::UNICODE
                | InputFlags::FASTPATH_INPUT_2,
            keyboard_layout: 0,
            keyboard_type: None,
            keyboard_subtype: 0,
            keyboard_function_key: 128,
            keyboard_ime_filename: String::new(),
        }),
        CapabilitySet::Sound(Sound {
            flags: SoundFlags::BEEPS,
        }),
        CapabilitySet::VirtualChannel(VirtualChannel {
            flags: VirtualChannelFlags::NO_COMPRESSION,
            chunk_size: None,
        }),
        CapabilitySet::MultiFragmentUpdate(MultifragmentUpdate {
            max_request_size: 16 * 1024 * 1024,
        }),
        CapabilitySet::BitmapCodecs(BitmapCodecs(Vec::new())),
    ]
}

pub async fn run_rdp_accept_loop(
    listener: TcpListener,
    config: MockConfig,
    identity: Arc<ServerIdentity>,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    control_tx: broadcast::Sender<ControlCmd>,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => break,
            accepted = listener.accept() => {
                let Ok((tcp_stream, peer_addr)) = accepted else {
                    break;
                };
                let _ = tcp_stream.set_nodelay(true);
                let cfg = config.clone();
                let id = Arc::clone(&identity);
                let m = Arc::clone(&metrics);
                let inp = Arc::clone(&recorded_inputs);
                let rx = control_tx.subscribe();
                tokio::spawn(async move {
                    if let Err(err) = handle_client(tcp_stream, peer_addr, cfg, id, m, inp, rx).await {
                        debug!(error = %err, "mock RDP client session ended");
                    }
                });
            }
        }
    }
}

fn security_protocol_for(mode: AuthMode) -> SecurityProtocol {
    match mode {
        AuthMode::Auto => SecurityProtocol::SSL | SecurityProtocol::HYBRID | SecurityProtocol::HYBRID_EX,
        AuthMode::Nla => SecurityProtocol::HYBRID | SecurityProtocol::HYBRID_EX,
        AuthMode::Tls => SecurityProtocol::SSL,
        AuthMode::None => SecurityProtocol::empty(),
    }
}

async fn handle_client(
    tcp_stream: TcpStream,
    peer_addr: std::net::SocketAddr,
    config: MockConfig,
    identity: Arc<ServerIdentity>,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    mut control_rx: broadcast::Receiver<ControlCmd>,
) -> anyhow::Result<()> {
    {
        let mut m = metrics.lock().expect("metrics lock");
        m.total_connections += 1;
    }

    let session_start = Instant::now();
    let desktop_size = DesktopSize {
        width: config.desktop_width,
        height: config.desktop_height,
    };

    let security = security_protocol_for(config.auth_mode);
    let mut acceptor = Acceptor::new(security, desktop_size, build_server_capabilities(desktop_size), None);
    acceptor.set_honor_client_desktop_size(config.honor_client_desktop_size);
    acceptor.attach_static_channel(TestRdpsndProcessor::new(
        config.rdpsnd_version,
        config.audio_sample_rate,
        config.audio_channels,
        Arc::clone(&metrics),
        session_start,
    ));

    let framed = TokioFramed::new(tcp_stream);
    let begin_res = accept_begin(framed, &mut acceptor).await?;

    match begin_res {
        BeginResult::Continue(framed) => {
            run_post_tls_session(
                framed,
                acceptor,
                config,
                metrics,
                recorded_inputs,
                &mut control_rx,
                session_start,
                false,
            )
            .await
        }
        BeginResult::ShouldUpgrade(tcp_stream) => {
            let protocol = acceptor
                .reached_security_upgrade()
                .unwrap_or(SecurityProtocol::SSL);
            let tls_stream = identity.tls_acceptor.accept(tcp_stream).await?;
            let mut tls_framed = TokioFramed::new(tls_stream);
            acceptor.mark_security_upgrade_as_done();

            let did_credssp = acceptor.should_perform_credssp();
            if did_credssp {
                run_credssp(
                    &mut tls_framed,
                    protocol,
                    ServerName::new(peer_addr.ip().to_string()),
                    identity.spki_pub_key.clone(),
                    CredsspExpected {
                        username: &config.username,
                        domain: &config.domain,
                        password: &config.password,
                    },
                    &metrics,
                )
                .await?;
                acceptor.mark_credssp_as_done();
            }

            run_post_tls_session(
                tls_framed,
                acceptor,
                config,
                metrics,
                recorded_inputs,
                &mut control_rx,
                session_start,
                did_credssp,
            )
            .await
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_post_tls_session<S>(
    mut framed: TokioFramed<S>,
    mut acceptor: Acceptor,
    config: MockConfig,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: Arc<Mutex<Vec<RecordedInput>>>,
    control_rx: &mut broadcast::Receiver<ControlCmd>,
    session_start: Instant,
    did_credssp: bool,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let mut session_guard: Option<ActiveSessionGuard> = None;
    let mut scene = DisplaySceneState::new(config.desktop_width, config.desktop_height);
    let mut current_encoding = config.pixel_encoding;
    let mut initial_pointer_sent = false;
    let mut current_desktop_size = DesktopSize {
        width: config.desktop_width,
        height: config.desktop_height,
    };

    loop {
        let (new_framed, mut result) = accept_finalize(framed, &mut acceptor).await?;
        framed = new_framed;

        // Check ClientInfo credentials when CredSSP was skipped (TLS mode or Auto->TLS fallback)
        // and the client supplies non-empty credentials.
        if !did_credssp
            && matches!(config.auth_mode, AuthMode::Tls | AuthMode::Auto)
            && !config.username.is_empty()
            && let Some(ref creds) = result.credentials
            && !creds.username.is_empty()
        {
            let domain_ok = config.domain.is_empty()
                || creds
                    .domain
                    .as_deref()
                    .unwrap_or("")
                    .eq_ignore_ascii_case(&config.domain);
            let creds_match =
                creds.username == config.username && creds.password == config.password && domain_ok;
            if !creds_match {
                {
                    let mut m = metrics.lock().expect("metrics lock");
                    m.auth_failures += 1;
                    m.last_disconnect_reason =
                        Some("auth failed: TLS ClientInfo credentials mismatch".to_owned());
                }
                drop(session_guard.take());
                send_error_info_and_dpum(
                    &mut framed,
                    result.io_channel_id,
                    result.user_channel_id,
                    0x0001_0000,
                    ErrorInfo::ProtocolIndependentCode(ProtocolIndependentCode::ServerDeniedConnection),
                )
                .await?;
                break;
            }
        }

        let guard = session_guard
            .get_or_insert_with(|| ActiveSessionGuard::acquire(Arc::clone(&metrics)));

        let share_id = 0x0001_0000u32;
        if let Some(bmp_cap) = result.capabilities.iter().find_map(|c| match c {
            CapabilitySet::Bitmap(b) => Some(b),
            _ => None,
        }) {
            current_desktop_size = DesktopSize {
                width: bmp_cap.desktop_width,
                height: bmp_cap.desktop_height,
            };
        }
        scene.resize(current_desktop_size.width, current_desktop_size.height);

        // Process any input backlog received during finalization
        for backlog_frame in core::mem::take(&mut result.input_events) {
            if let Some(fp) = parse_fastpath_backlog_frame(&backlog_frame) {
                record_fastpath_inputs(&fp, &mut scene, &recorded_inputs, session_start);
            }
        }

        // Start static channels (sends SNDC_FORMATS on rdpsnd if joined)
        if let Some(rdpsnd_id) = result.static_channels.get_channel_id_by_type::<TestRdpsndProcessor>()
            && let Some(svc) = result.static_channels.get_by_channel_id_mut(rdpsnd_id)
        {
            let msgs = svc.start()?;
            if !msgs.is_empty() {
                let bytes = server_encode_svc_messages(msgs, rdpsnd_id, result.user_channel_id)?;
                framed.write_all(&bytes).await?;
            }
        }

        if config.emit_initial_pointer && !initial_pointer_sent {
            initial_pointer_sent = true;
            let rgba_ptr = encode_pointer_update_fastpath(&crate::PointerTestUpdate::Rgba {
                cache_index: 1,
                width: 4,
                height: 4,
                hot_x: 1,
                hot_y: 1,
                rgba: vec![0xFF; 4 * 4 * 4],
            })?;
            framed.write_all(&rgba_ptr).await?;
        }

        let outcome = run_active_loop(
            &mut framed,
            &mut result,
            &config,
            &mut scene,
            &mut current_encoding,
            &metrics,
            &recorded_inputs,
            control_rx,
            session_start,
            share_id,
            guard,
        )
        .await?;

        match outcome {
            LoopOutcome::DeactivateAll { new_size } => {
                let target_size = new_size.map_or(current_desktop_size, |(w, h)| DesktopSize {
                    width: w,
                    height: h,
                });
                current_desktop_size = target_size;
                send_deactivate_all(&mut framed, result.io_channel_id, result.user_channel_id, share_id).await?;
                acceptor = Acceptor::new_deactivation_reactivation(
                    acceptor,
                    core::mem::take(&mut result.static_channels),
                    target_size,
                )?;
                metrics.lock().expect("metrics lock").reactivations += 1;
                continue;
            }
            LoopOutcome::Closed => break,
        }
    }

    drop(session_guard.take());

    Ok(())
}

enum LoopOutcome {
    DeactivateAll { new_size: Option<(u16, u16)> },
    Closed,
}

fn concat_pdu_slice(pdus: &[Vec<u8>]) -> Vec<u8> {
    let total_len: usize = pdus.iter().map(Vec::len).sum();
    let mut batch = Vec::with_capacity(total_len);
    for f in pdus {
        batch.extend_from_slice(f);
    }
    batch
}

fn record_frame_sent(
    metrics: &Arc<Mutex<ServerMetricsInner>>,
    session_start: Instant,
    ack: Option<FrameAckSlot>,
) {
    let total = {
        let mut m = metrics.lock().expect("metrics lock");
        m.frames_sent += 1;
        m.last_frame_timestamp_ms = Some(session_start.elapsed().as_millis() as u32);
        m.frames_sent
    };
    if let Some(tx_slot) = ack
        && let Some(tx) = tx_slot.lock().expect("ack").take()
    {
        let _ = tx.send(total);
    }
}

fn spawn_scene_encode(
    scene: DisplaySceneState,
    encoding: PixelEncoding,
    ack: Option<FrameAckSlot>,
) -> EncodeSceneTask {
    tokio::task::spawn_blocking(move || {
        let frames = encode_scene_fastpath_frames(&scene, encoding)?;
        Ok((frames, ack))
    })
}

async fn await_optional_encode(
    opt: &mut Option<EncodeSceneTask>,
) -> anyhow::Result<(Vec<Vec<u8>>, Option<FrameAckSlot>)> {
    match opt.as_mut() {
        Some(handle) => match handle.await {
            Ok(res) => res,
            Err(join_err) => Err(anyhow::anyhow!("frame encode task failed: {join_err}")),
        },
        None => std::future::pending().await,
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_active_loop<S>(
    framed: &mut TokioFramed<S>,
    result: &mut AcceptorResult,
    config: &MockConfig,
    scene: &mut DisplaySceneState,
    current_encoding: &mut PixelEncoding,
    metrics: &Arc<Mutex<ServerMetricsInner>>,
    recorded_inputs: &Arc<Mutex<Vec<RecordedInput>>>,
    control_rx: &mut broadcast::Receiver<ControlCmd>,
    session_start: Instant,
    share_id: u32,
    session_guard: &mut ActiveSessionGuard,
) -> anyhow::Result<LoopOutcome>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let audio_tick_ms = config.auto_audio_interval_ms.unwrap_or(10_000);
    let mut audio_interval = tokio::time::interval(Duration::from_millis(audio_tick_ms.max(5)));
    audio_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut frame_chunk_interval =
        tokio::time::interval(Duration::from_millis(FRAME_CHUNK_INTERVAL_MS));
    frame_chunk_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let audio_enabled = config.audio_hz > 0 && config.auto_audio_interval_ms.is_some();
    let mut beat_tick: u64 = 0;
    let mut pending_audio_bursts: Vec<PendingAudioBurst> = Vec::new();
    let mut pending_trainings: Vec<PendingTraining> = Vec::new();
    let mut initial_frame_sent = false;
    let mut pending_frame_slices: VecDeque<Vec<u8>> = VecDeque::new();
    let mut pending_frame_ack: Option<FrameAckSlot> = None;
    let mut pending_frame_requests: VecDeque<(Option<PixelEncoding>, Option<FrameAckSlot>)> =
        VecDeque::new();
    let mut active_frame_encode: Option<EncodeSceneTask> =
        Some(spawn_scene_encode(scene.clone(), *current_encoding, None));

    loop {
        tokio::select! {
            encode_res = await_optional_encode(&mut active_frame_encode), if active_frame_encode.is_some() => {
                active_frame_encode = None;
                let (frames, ack) = encode_res?;
                if audio_enabled && is_rdpsnd_ready(result) && frames.len() > AUDIO_GATED_TILE_CHUNK_PDUS {
                    let mut slices: VecDeque<Vec<u8>> = frames
                        .chunks(AUDIO_GATED_TILE_CHUNK_PDUS)
                        .map(concat_pdu_slice)
                        .collect();
                    if let Some(first_slice) = slices.pop_front() {
                        framed.write_all(&first_slice).await?;
                    }
                    if slices.is_empty() {
                        initial_frame_sent = true;
                        record_frame_sent(metrics, session_start, ack);
                        if let Some((enc_override, next_ack)) = pending_frame_requests.pop_front() {
                            if let Some(enc) = enc_override {
                                *current_encoding = enc;
                            }
                            active_frame_encode = Some(spawn_scene_encode(
                                scene.clone(),
                                *current_encoding,
                                next_ack,
                            ));
                        }
                    } else {
                        pending_frame_slices = slices;
                        pending_frame_ack = ack;
                        frame_chunk_interval.reset();
                    }
                } else {
                    let batch = concat_pdu_slice(&frames);
                    framed.write_all(&batch).await?;
                    initial_frame_sent = true;
                    record_frame_sent(metrics, session_start, ack);
                    if let Some((enc_override, next_ack)) = pending_frame_requests.pop_front() {
                        if let Some(enc) = enc_override {
                            *current_encoding = enc;
                        }
                        active_frame_encode = Some(spawn_scene_encode(
                            scene.clone(),
                            *current_encoding,
                            next_ack,
                        ));
                    }
                }
            }

            _ = frame_chunk_interval.tick(), if !pending_frame_slices.is_empty() => {
                if let Some(next_slice) = pending_frame_slices.pop_front() {
                    framed.write_all(&next_slice).await?;
                }
                if pending_frame_slices.is_empty() {
                    initial_frame_sent = true;
                    let ack = pending_frame_ack.take();
                    record_frame_sent(metrics, session_start, ack);
                    if let Some((enc_override, next_ack)) = pending_frame_requests.pop_front() {
                        if let Some(enc) = enc_override {
                            *current_encoding = enc;
                        }
                        active_frame_encode = Some(spawn_scene_encode(
                            scene.clone(),
                            *current_encoding,
                            next_ack,
                        ));
                    }
                }
            }

            pdu = framed.read_pdu() => {
                match pdu {
                    Ok((Action::FastPath, frame)) => {
                        if let Ok(fp) = decode::<FastPathInput>(&frame) {
                            record_fastpath_inputs(&fp, scene, recorded_inputs, session_start);
                        }
                    }
                    Ok((Action::X224, frame)) => {
                        let msg = decode::<X224<McsMessage<'_>>>(&frame)?;
                        match msg.0 {
                            McsMessage::SendDataRequest(data) => {
                                if data.channel_id == result.io_channel_id {
                                    if let Ok(sc) = decode::<ShareControlHeader>(data.user_data.as_ref())
                                        && let ShareControlPdu::Data(sd) = sc.share_control_pdu
                                    {
                                        match sd.share_data_pdu {
                                            ShareDataPdu::ShutdownRequest => {
                                                send_shutdown_denied(
                                                    framed,
                                                    result.io_channel_id,
                                                    result.user_channel_id,
                                                    share_id,
                                                ).await?;
                                            }
                                            ShareDataPdu::Input(inp) => {
                                                record_slowpath_inputs(&inp.0, scene, recorded_inputs, session_start);
                                            }
                                            _ => {}
                                        }
                                    }
                                } else if let Some(svc) = result.static_channels.get_by_channel_id_mut(data.channel_id) {
                                    let reply = svc.process(&data.user_data)?;
                                    if !reply.is_empty() {
                                        let bytes = server_encode_svc_messages(reply, data.channel_id, result.user_channel_id)?;
                                        framed.write_all(&bytes).await?;
                                    }
                                    if is_rdpsnd_ready(result) {
                                        for (payload_len, ack) in pending_trainings.drain(..) {
                                            send_rdpsnd_training(framed, result, payload_len).await?;
                                            if let Some(tx_slot) = ack
                                                && let Some(tx) = tx_slot.lock().expect("ack").take()
                                            {
                                                let _ = tx.send(());
                                            }
                                        }
                                        for (blocks, interval_ms, ack) in pending_audio_bursts.drain(..) {
                                            for idx in 0..blocks {
                                                send_one_audio_block(framed, result, config.audio_hz, config.audio_chunk_ms).await?;
                                                if interval_ms > 0 && idx + 1 < blocks {
                                                    tokio::time::sleep(Duration::from_millis(interval_ms)).await;
                                                }
                                            }
                                            if let Some(tx_slot) = ack
                                                && let Some(tx) = tx_slot.lock().expect("ack").take()
                                            {
                                                let _ = tx.send(());
                                            }
                                        }
                                    }
                                }
                            }
                            McsMessage::DisconnectProviderUltimatum(dpum) => {
                                if let Some(handle) = active_frame_encode.take() {
                                    handle.abort();
                                }
                                pending_frame_slices.clear();
                                drop(pending_frame_ack.take());
                                pending_frame_requests.clear();
                                metrics.lock().expect("metrics lock").last_disconnect_reason =
                                    Some(format!("client DPUM: {:?}", dpum.reason));
                                session_guard.release();
                                return Ok(LoopOutcome::Closed);
                            }
                            _ => {}
                        }
                    }
                    Err(e) => {
                        if let Some(handle) = active_frame_encode.take() {
                            handle.abort();
                        }
                        pending_frame_slices.clear();
                        drop(pending_frame_ack.take());
                        pending_frame_requests.clear();
                        metrics.lock().expect("metrics lock").last_disconnect_reason =
                            Some(format!("socket closed: {e}"));
                        session_guard.release();
                        return Ok(LoopOutcome::Closed);
                    }
                }
            }

            ctrl = control_rx.recv() => {
                match ctrl {
                    Ok(ControlCmd::DeactivateAll { new_size, ack }) => {
                        if let Some(handle) = active_frame_encode.take() {
                            handle.abort();
                        }
                        pending_frame_slices.clear();
                        drop(pending_frame_ack.take());
                        pending_frame_requests.clear();
                        if let Some(tx_slot) = ack
                            && let Some(tx) = tx_slot.lock().expect("ack").take()
                        {
                            let _ = tx.send(());
                        }
                        return Ok(LoopOutcome::DeactivateAll { new_size });
                    }
                    Ok(ControlCmd::Disconnect { error_info }) => {
                        if let Some(handle) = active_frame_encode.take() {
                            handle.abort();
                        }
                        pending_frame_slices.clear();
                        drop(pending_frame_ack.take());
                        pending_frame_requests.clear();
                        metrics.lock().expect("metrics lock").last_disconnect_reason =
                            Some(error_info.description());
                        session_guard.release();
                        send_error_info_and_dpum(
                            framed,
                            result.io_channel_id,
                            result.user_channel_id,
                            share_id,
                            error_info,
                        ).await?;
                        let _ = framed.get_inner_mut().0.shutdown().await;
                        return Ok(LoopOutcome::Closed);
                    }
                    Ok(ControlCmd::SocketDrop) => {
                        if let Some(handle) = active_frame_encode.take() {
                            handle.abort();
                        }
                        pending_frame_slices.clear();
                        drop(pending_frame_ack.take());
                        pending_frame_requests.clear();
                        metrics.lock().expect("metrics lock").last_disconnect_reason =
                            Some("simulated socket drop".to_owned());
                        session_guard.release();
                        let _ = framed.get_inner_mut().0.shutdown().await;
                        return Ok(LoopOutcome::Closed);
                    }
                    Ok(ControlCmd::Frame { encoding_override, ack }) => {
                        if active_frame_encode.is_some() || !pending_frame_slices.is_empty() {
                            pending_frame_requests.push_back((encoding_override, ack));
                        } else {
                            if let Some(enc) = encoding_override {
                                *current_encoding = enc;
                            }
                            active_frame_encode = Some(spawn_scene_encode(
                                scene.clone(),
                                *current_encoding,
                                ack,
                            ));
                        }
                    }
                    Ok(ControlCmd::SlowPathFrame { encoding_override, ack }) => {
                        let enc = encoding_override.unwrap_or(*current_encoding);
                        let pdu = encode_slowpath_bitmap_pdu(
                            result.io_channel_id,
                            result.user_channel_id,
                            share_id,
                            scene,
                            SlowPathTile {
                                x0: 0,
                                y0: 0,
                                width: usize::from(scene.width).min(64),
                                height: usize::from(scene.height).min(64),
                            },
                            enc,
                        )?;
                        let total = {
                            let mut m = metrics.lock().expect("metrics lock");
                            m.frames_sent += 1;
                            m.frames_sent
                        };
                        framed.write_all(&pdu).await?;
                        if let Some(tx_slot) = ack
                            && let Some(tx) = tx_slot.lock().expect("ack").take()
                        {
                            let _ = tx.send(total);
                        }
                    }
                    Ok(ControlCmd::AudioBurst { blocks, interval_ms, ack }) => {
                        if is_rdpsnd_ready(result) {
                            for idx in 0..blocks {
                                send_one_audio_block(framed, result, config.audio_hz, config.audio_chunk_ms).await?;
                                if interval_ms > 0 && idx + 1 < blocks {
                                    tokio::time::sleep(Duration::from_millis(interval_ms)).await;
                                }
                            }
                            if let Some(tx_slot) = ack
                                && let Some(tx) = tx_slot.lock().expect("ack").take()
                            {
                                let _ = tx.send(());
                            }
                        } else {
                            pending_audio_bursts.push((blocks, interval_ms, ack));
                        }
                    }
                    Ok(ControlCmd::RdpsndTraining { payload_len, ack }) => {
                        if is_rdpsnd_ready(result) {
                            send_rdpsnd_training(framed, result, payload_len).await?;
                            if let Some(tx_slot) = ack
                                && let Some(tx) = tx_slot.lock().expect("ack").take()
                            {
                                let _ = tx.send(());
                            }
                        } else {
                            pending_trainings.push((payload_len, ack));
                        }
                    }
                    Ok(ControlCmd::RdpsndVolume { left, right, ack }) => {
                        if let Some(rdpsnd_id) = result.static_channels.get_channel_id_by_type::<TestRdpsndProcessor>()
                            && let Some(svc) = result.static_channels.get_by_channel_id_mut(rdpsnd_id)
                            && let Some(proc) = svc.channel_processor_downcast_mut::<TestRdpsndProcessor>()
                        {
                            let msg = proc.build_volume_msg(left, right);
                            let bytes = server_encode_svc_messages(vec![msg], rdpsnd_id, result.user_channel_id)?;
                            framed.write_all(&bytes).await?;
                        }
                        if let Some(tx_slot) = ack
                            && let Some(tx) = tx_slot.lock().expect("ack").take()
                        {
                            let _ = tx.send(());
                        }
                    }
                    Ok(ControlCmd::PointerUpdate { kind, ack }) => {
                        let bytes = encode_pointer_update_fastpath(&kind)?;
                        framed.write_all(&bytes).await?;
                        if let Some(tx_slot) = ack
                            && let Some(tx) = tx_slot.lock().expect("ack").take()
                        {
                            let _ = tx.send(());
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(n, "control broadcast lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        if let Some(handle) = active_frame_encode.take() {
                            handle.abort();
                        }
                        pending_frame_slices.clear();
                        drop(pending_frame_ack.take());
                        pending_frame_requests.clear();
                        session_guard.release();
                        return Ok(LoopOutcome::Closed);
                    }
                }
            }

            _ = audio_interval.tick(), if audio_enabled && is_rdpsnd_ready(result) => {
                let sent = send_one_audio_block(framed, result, config.audio_hz, config.audio_chunk_ms).await?;
                if sent {
                    beat_tick += 1;
                    // Toggle header audio beat every 500ms (starting after first 10 ticks)
                    let new_beat = beat_tick >= 10 && (beat_tick % 25) < 3;
                    if new_beat != scene.audio_beat_active {
                        scene.audio_beat_active = new_beat;
                        if initial_frame_sent && pending_frame_slices.is_empty() {
                            let _ = send_header_beat_frame(framed, scene, *current_encoding, metrics, session_start).await;
                        }
                    }
                }
            }
        }
    }
}

fn is_rdpsnd_ready(result: &AcceptorResult) -> bool {
    let Some(rdpsnd_id) = result.static_channels.get_channel_id_by_type::<TestRdpsndProcessor>() else {
        return false;
    };
    result
        .static_channels
        .get_by_channel_id(rdpsnd_id)
        .and_then(|svc| svc.channel_processor_downcast_ref::<TestRdpsndProcessor>())
        .is_some_and(|proc| proc.is_ready())
}

async fn send_rdpsnd_training<S>(
    framed: &mut TokioFramed<S>,
    result: &mut AcceptorResult,
    payload_len: usize,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    if let Some(rdpsnd_id) = result.static_channels.get_channel_id_by_type::<TestRdpsndProcessor>()
        && let Some(svc) = result.static_channels.get_by_channel_id_mut(rdpsnd_id)
        && let Some(proc) = svc.channel_processor_downcast_mut::<TestRdpsndProcessor>()
    {
        let msg = proc.build_training_msg(payload_len);
        let bytes = server_encode_svc_messages(vec![msg], rdpsnd_id, result.user_channel_id)?;
        framed.write_all(&bytes).await?;
    }
    Ok(())
}

async fn send_one_audio_block<S>(
    framed: &mut TokioFramed<S>,
    result: &mut AcceptorResult,
    audio_hz: u32,
    chunk_ms: u32,
) -> anyhow::Result<bool>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let Some(rdpsnd_id) = result.static_channels.get_channel_id_by_type::<TestRdpsndProcessor>() else {
        return Ok(false);
    };
    let msg_opt = if let Some(svc) = result.static_channels.get_by_channel_id_mut(rdpsnd_id) {
        if let Some(proc) = svc.channel_processor_downcast_mut::<TestRdpsndProcessor>() {
            if proc.is_ready() {
                Some(proc.build_tone_wave_msg(audio_hz, chunk_ms))
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    if let Some(msg) = msg_opt {
        let bytes = server_encode_svc_messages(vec![msg], rdpsnd_id, result.user_channel_id)?;
        framed.write_all(&bytes).await?;
        return Ok(true);
    }
    Ok(false)
}

async fn send_header_beat_frame<S>(
    framed: &mut TokioFramed<S>,
    scene: &DisplaySceneState,
    encoding: PixelEncoding,
    metrics: &Arc<Mutex<ServerMetricsInner>>,
    session_start: Instant,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let frames = encode_scene_region_fastpath_frames(scene, encoding, 0, 48)?;
    let total_len: usize = frames.iter().map(Vec::len).sum();
    let mut batch = Vec::with_capacity(total_len);
    for f in frames {
        batch.extend_from_slice(&f);
    }
    {
        let mut m = metrics.lock().expect("metrics lock");
        m.frames_sent += 1;
        m.last_frame_timestamp_ms = Some(session_start.elapsed().as_millis() as u32);
    }
    framed.write_all(&batch).await?;
    Ok(())
}

async fn send_deactivate_all<S>(
    framed: &mut TokioFramed<S>,
    io_channel_id: u16,
    user_channel_id: u16,
    share_id: u32,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let sc = ShareControlHeader {
        share_id,
        pdu_source: io_channel_id,
        share_control_pdu: ShareControlPdu::ServerDeactivateAll(
            ironrdp::pdu::rdp::headers::ServerDeactivateAll,
        ),
    };
    let user_data = Cow::Owned(encode_vec(&sc)?);
    let mcs = SendDataIndication {
        initiator_id: user_channel_id,
        channel_id: io_channel_id,
        user_data,
    };
    framed.write_all(&encode_vec(&X224(mcs))?).await?;
    Ok(())
}

async fn send_shutdown_denied<S>(
    framed: &mut TokioFramed<S>,
    io_channel_id: u16,
    user_channel_id: u16,
    share_id: u32,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let sd = ShareDataHeader {
        stream_priority: StreamPriority::Medium,
        compression_flags: ironrdp::pdu::rdp::headers::CompressionFlags::empty(),
        compression_type: ironrdp::pdu::rdp::client_info::CompressionType::K8,
        share_data_pdu: ShareDataPdu::ShutdownDenied,
    };
    let sc = ShareControlHeader {
        share_id,
        pdu_source: io_channel_id,
        share_control_pdu: ShareControlPdu::Data(sd),
    };
    let user_data = Cow::Owned(encode_vec(&sc)?);
    let mcs = SendDataIndication {
        initiator_id: user_channel_id,
        channel_id: io_channel_id,
        user_data,
    };
    framed.write_all(&encode_vec(&X224(mcs))?).await?;
    Ok(())
}

async fn send_error_info_and_dpum<S>(
    framed: &mut TokioFramed<S>,
    io_channel_id: u16,
    user_channel_id: u16,
    share_id: u32,
    error_info: ErrorInfo,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    let sd = ShareDataHeader {
        stream_priority: StreamPriority::Medium,
        compression_flags: ironrdp::pdu::rdp::headers::CompressionFlags::empty(),
        compression_type: ironrdp::pdu::rdp::client_info::CompressionType::K8,
        share_data_pdu: ShareDataPdu::ServerSetErrorInfo(ServerSetErrorInfoPdu(error_info)),
    };
    let sc = ShareControlHeader {
        share_id,
        pdu_source: io_channel_id,
        share_control_pdu: ShareControlPdu::Data(sd),
    };
    let user_data = Cow::Owned(encode_vec(&sc)?);
    let mcs = SendDataIndication {
        initiator_id: user_channel_id,
        channel_id: io_channel_id,
        user_data,
    };
    framed.write_all(&encode_vec(&X224(mcs))?).await?;

    let dpum = DisconnectProviderUltimatum {
        reason: DisconnectReason::ProviderInitiated,
    };
    framed.write_all(&encode_vec(&X224(dpum))?).await?;
    Ok(())
}

fn record_fastpath_inputs(
    fp: &FastPathInput,
    scene: &mut DisplaySceneState,
    recorded: &Arc<Mutex<Vec<RecordedInput>>>,
    session_start: Instant,
) {
    let ts = session_start.elapsed().as_millis() as u64;
    let mut guard = recorded.lock().expect("inputs lock");

    for &ev in fp.input_events() {
        match ev {
            FastPathInputEvent::KeyboardEvent(flags, code) => {
                let extended = flags.contains(KeyboardFlags::EXTENDED);
                let down = !flags.contains(KeyboardFlags::RELEASE);
                if down {
                    scene.last_key_code = u16::from(code);
                }
                guard.push(RecordedInput::Scancode {
                    code,
                    extended,
                    down,
                    timestamp_ms: ts,
                });
            }
            FastPathInputEvent::UnicodeKeyboardEvent(flags, code_unit) => {
                let down = !flags.contains(KeyboardFlags::RELEASE);
                if down {
                    scene.last_key_code = code_unit;
                }
                guard.push(RecordedInput::Unicode {
                    code_unit,
                    down,
                    timestamp_ms: ts,
                });
            }
            FastPathInputEvent::MouseEvent(m) => {
                scene.pointer_x = m.x_position.min(scene.width.saturating_sub(1));
                scene.pointer_y = m.y_position.min(scene.height.saturating_sub(1));
                let down = m.flags.contains(PointerFlags::DOWN);
                let mut mask = 0u8;
                if m.flags.contains(PointerFlags::LEFT_BUTTON) {
                    mask |= 0x01;
                    scene.left_pressed = down;
                }
                if m.flags.contains(PointerFlags::RIGHT_BUTTON) {
                    mask |= 0x02;
                    scene.right_pressed = down;
                }
                if m.flags.contains(PointerFlags::MIDDLE_BUTTON_OR_WHEEL)
                    && !m.flags.contains(PointerFlags::VERTICAL_WHEEL)
                    && !m.flags.contains(PointerFlags::HORIZONTAL_WHEEL)
                {
                    mask |= 0x04;
                }
                let action = if m.flags.contains(PointerFlags::VERTICAL_WHEEL) {
                    "wheel_vertical"
                } else if m.flags.contains(PointerFlags::HORIZONTAL_WHEEL) {
                    "wheel_horizontal"
                } else if mask != 0 && down {
                    "button_down"
                } else if mask != 0 {
                    "button_up"
                } else {
                    "move"
                };
                guard.push(RecordedInput::Pointer {
                    x: m.x_position,
                    y: m.y_position,
                    button_mask: mask,
                    action: action.to_owned(),
                    wheel_delta: m.number_of_wheel_rotation_units,
                    timestamp_ms: ts,
                });
            }
            FastPathInputEvent::MouseEventEx(mx) => {
                let down = mx.flags.contains(PointerXFlags::DOWN);
                let mut mask = 0u8;
                if mx.flags.contains(PointerXFlags::BUTTON1) {
                    mask |= 0x08;
                }
                if mx.flags.contains(PointerXFlags::BUTTON2) {
                    mask |= 0x10;
                }
                guard.push(RecordedInput::Pointer {
                    x: mx.x_position,
                    y: mx.y_position,
                    button_mask: mask,
                    action: if down { "xbutton_down" } else { "xbutton_up" }.to_owned(),
                    wheel_delta: 0,
                    timestamp_ms: ts,
                });
            }
            _ => {}
        }
    }
}

fn parse_fastpath_backlog_frame(frame: &[u8]) -> Option<FastPathInput> {
    let &first = frame.first()?;
    if matches!(Action::from_fp_output_header(first), Ok(Action::FastPath)) {
        decode::<FastPathInput>(frame).ok()
    } else {
        None
    }
}

fn record_slowpath_inputs(
    events: &[InputEvent],
    scene: &mut DisplaySceneState,
    recorded: &Arc<Mutex<Vec<RecordedInput>>>,
    session_start: Instant,
) {
    let ts = session_start.elapsed().as_millis() as u64;
    let mut guard = recorded.lock().expect("inputs lock");
    for ev in events {
        if let InputEvent::ScanCode(sc) = ev {
            guard.push(RecordedInput::Scancode {
                code: sc.key_code as u8,
                extended: false,
                down: true,
                timestamp_ms: ts,
            });
            scene.last_key_code = sc.key_code;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_backlog_frame_does_not_panic() {
        assert!(parse_fastpath_backlog_frame(&[]).is_none());
        assert!(parse_fastpath_backlog_frame(&[0x03]).is_none());
    }
}
