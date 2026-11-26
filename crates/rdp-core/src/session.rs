use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use ironrdp::core::{Decode as _, ReadCursor};
use ironrdp::pdu::Action;
use ironrdp::pdu::fast_path::{FastPathHeader, FastPathUpdatePdu, UpdateCode};
use ironrdp::pdu::surface_commands::{FrameAction, SurfaceCommand};
use ironrdp::session::{ActiveStage, ActiveStageBuilder, ActiveStageOutput};
use ironrdp::svc::SvcProcessorMessages;
use ironrdp_tokio::FramedWrite;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Notify, mpsc};
use tracing::{debug, trace, warn};

use crate::audio::AudioJitterBuffer;
use crate::connector::{ConnectedSession, connect_and_activate, run_deactivation_reactivation};
use crate::framebuffer::{DirtyRect, Framebuffer};
use crate::input::InputController;
use crate::rdpsnd::AerRdpsndProcessor;
use crate::types::{
    AudioReadStats, AuthCredentials, CertInfo, CertTrustDecision, ConnectConfig, CoreError,
    SessionCommand, SessionEvent, SessionState,
};

#[derive(Clone)]
pub struct SessionHandle {
    cmd_tx: mpsc::UnboundedSender<SessionCommand>,
    framebuffer: Arc<RwLock<Framebuffer>>,
    audio_buffer: Arc<Mutex<AudioJitterBuffer>>,
    cert_info: Arc<RwLock<Option<CertInfo>>>,
}

impl SessionHandle {
    pub fn submit_cert_decision(&self, decision: CertTrustDecision) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SubmitCertDecision(decision))
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn submit_credentials(&self, creds: AuthCredentials) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SubmitCredentials(creds))
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn send_pointer_event(
        &self,
        x: u16,
        y: u16,
        button_mask: u8,
        down: bool,
        wheel_delta: i16,
    ) -> Result<(), CoreError> {
        self.send_pointer_event_hv(x, y, button_mask, down, wheel_delta, 0)
    }

    pub fn send_pointer_event_hv(
        &self,
        x: u16,
        y: u16,
        button_mask: u8,
        down: bool,
        wheel_delta_v: i16,
        wheel_delta_h: i16,
    ) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SendPointer {
                x,
                y,
                button_mask,
                down,
                wheel_delta_v,
                wheel_delta_h,
            })
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn send_scancode(&self, code: u8, extended: bool, down: bool) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SendScancode {
                code,
                extended,
                down,
            })
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn send_unicode(&self, code_unit: u16, down: bool) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SendUnicode { code_unit, down })
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn set_audio_mute(&self, muted: bool) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SetAudioMute(muted))
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn set_audio_volume(&self, volume: f32) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::SetAudioVolume(volume))
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn disconnect(&self) -> Result<(), CoreError> {
        self.cmd_tx
            .send(SessionCommand::Disconnect)
            .map_err(|_| CoreError::ChannelClosed)
    }

    pub fn snapshot_rgba(&self) -> (u16, u16, Vec<u8>) {
        let fb = self.framebuffer.read().expect("framebuffer lock");
        (fb.width(), fb.height(), fb.data().to_vec())
    }

    pub fn with_framebuffer_rgba<R>(&self, f: impl FnOnce(u16, u16, &[u8]) -> R) -> R {
        let fb = self.framebuffer.read().expect("framebuffer lock");
        f(fb.width(), fb.height(), fb.data())
    }

    pub fn framebuffer_sha256_hex(&self) -> String {
        let fb = self.framebuffer.read().expect("framebuffer lock");
        fb.sha256_hex()
    }

    pub fn cert_info(&self) -> Option<CertInfo> {
        self.cert_info.read().expect("cert_info lock").clone()
    }

    pub fn audio_buffer(&self) -> Arc<Mutex<AudioJitterBuffer>> {
        Arc::clone(&self.audio_buffer)
    }

    pub fn read_pcm_frames(
        &self,
        out: &mut [u8],
        frames_played_since_last_read: usize,
    ) -> AudioReadStats {
        let mut jb = self.audio_buffer.lock().expect("audio_buffer lock");
        jb.read_pcm_frames(out, frames_played_since_last_read)
    }
}

pub fn connect(
    config: ConnectConfig,
    initial_creds: Option<AuthCredentials>,
) -> Result<(SessionHandle, mpsc::UnboundedReceiver<SessionEvent>), CoreError> {
    config.validate()?;

    let (aligned_w, clamped_h) = config.aligned_dimensions();
    let confirm_notify = Arc::new(Notify::new());
    let audio_buffer = Arc::new(Mutex::new(AudioJitterBuffer::new(Arc::clone(&confirm_notify))));
    let framebuffer = Arc::new(RwLock::new(Framebuffer::new(aligned_w, clamped_h)));
    let cert_info_slot = Arc::new(RwLock::new(None));

    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (event_tx, event_rx) = mpsc::unbounded_channel();

    let handle = SessionHandle {
        cmd_tx,
        framebuffer: Arc::clone(&framebuffer),
        audio_buffer: Arc::clone(&audio_buffer),
        cert_info: Arc::clone(&cert_info_slot),
    };

    tokio::spawn(run_session_task(
        config,
        initial_creds,
        framebuffer,
        audio_buffer,
        confirm_notify,
        cert_info_slot,
        cmd_rx,
        event_tx,
    ));

    Ok((handle, event_rx))
}

/// Non-mutating scan of a Fast-Path server payload to detect `UpdateCode::Synchronize`
/// or `SurfaceCommand::FrameMarker(FrameAction::End)` which `ironrdp-session` otherwise ignores.
fn scan_fastpath_frame_sync(payload: &[u8]) -> bool {
    let mut cursor = ReadCursor::new(payload);
    let Ok(header) = FastPathHeader::decode(&mut cursor) else {
        return false;
    };
    let data_len = header.data_length.min(cursor.len());
    let mut inner = ReadCursor::new(cursor.read_slice(data_len));
    while !inner.is_empty() {
        let Ok(update) = FastPathUpdatePdu::decode(&mut inner) else {
            break;
        };
        if update.update_code == UpdateCode::Synchronize {
            return true;
        }
        if update.update_code == UpdateCode::SurfaceCommands && update.compression_flags.is_none() {
            let mut cmd_cur = ReadCursor::new(update.data);
            while cmd_cur.len() >= 2 {
                let Ok(cmd) = SurfaceCommand::decode(&mut cmd_cur) else {
                    break;
                };
                if let SurfaceCommand::FrameMarker(marker) = cmd
                    && marker.frame_action == FrameAction::End
                {
                    return true;
                }
            }
        }
    }
    false
}

#[derive(Default)]
struct CursorTracker {
    x: u16,
    y: u16,
    visible: bool,
    hotspot_x: u16,
    hotspot_y: u16,
    width: u16,
    height: u16,
    rgba_pixels: Vec<u8>,
}

impl CursorTracker {
    fn emit(&self, event_tx: &mpsc::UnboundedSender<SessionEvent>) {
        let _ = event_tx.send(SessionEvent::CursorUpdated {
            x: self.x,
            y: self.y,
            visible: self.visible,
            hotspot_x: self.hotspot_x,
            hotspot_y: self.hotspot_y,
            width: self.width,
            height: self.height,
            rgba_pixels: self.rgba_pixels.clone(),
        });
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_session_task(
    config: ConnectConfig,
    initial_creds: Option<AuthCredentials>,
    framebuffer: Arc<RwLock<Framebuffer>>,
    audio_buffer: Arc<Mutex<AudioJitterBuffer>>,
    confirm_notify: Arc<Notify>,
    cert_info_slot: Arc<RwLock<Option<CertInfo>>>,
    mut cmd_rx: mpsc::UnboundedReceiver<SessionCommand>,
    event_tx: mpsc::UnboundedSender<SessionEvent>,
) {
    let _ = event_tx.send(SessionEvent::SessionStateChanged(SessionState::Connecting));

    let ConnectedSession {
        mut framed,
        mut connection_result,
        cert_info,
    } = match connect_and_activate(
        &config,
        initial_creds,
        Arc::clone(&audio_buffer),
        &event_tx,
        &mut cmd_rx,
    )
    .await
    {
        Ok(conn) => conn,
        Err(err) => {
            if let CoreError::CertMismatch { ref cert_info, .. } = err
                && let Ok(mut guard) = cert_info_slot.write()
            {
                *guard = Some((**cert_info).clone());
            }
            let _ = event_tx.send(SessionEvent::SessionStateChanged(
                SessionState::Disconnected {
                    reason: err.to_string(),
                    clean: false,
                },
            ));
            return;
        }
    };

    if let Ok(mut guard) = cert_info_slot.write() {
        *guard = Some(cert_info);
    }

    let mut cur_width = connection_result.desktop_size.width;
    let mut cur_height = connection_result.desktop_size.height;
    {
        let mut fb = framebuffer.write().expect("framebuffer lock");
        fb.resize(cur_width, cur_height);
    }

    let mut input_ctrl = InputController::new(cur_width, cur_height);
    let mut cursor = CursorTracker {
        visible: true,
        ..Default::default()
    };

    let mut active_stage: ActiveStage = ActiveStageBuilder {
        static_channels: std::mem::take(&mut connection_result.static_channels),
        user_channel_id: connection_result.user_channel_id,
        io_channel_id: connection_result.io_channel_id,
        message_channel_id: connection_result.message_channel_id,
        share_id: connection_result.share_id,
        compression_type: connection_result.compression_type,
        enable_server_pointer: connection_result.enable_server_pointer,
        pointer_software_rendering: connection_result.pointer_software_rendering,
    }
    .build();

    let session_start = Instant::now();
    let _ = event_tx.send(SessionEvent::SessionStateChanged(SessionState::Active {
        width: cur_width,
        height: cur_height,
    }));

    loop {
        tokio::select! {
            pdu_res = framed.read_pdu() => {
                match pdu_res {
                    Ok((action, frame)) => {
                        let frame_sync = if action == Action::FastPath {
                            scan_fastpath_frame_sync(&frame)
                        } else {
                            false
                        };

                        let outputs = {
                            let mut fb = framebuffer.write().expect("framebuffer lock");
                            active_stage.process(fb.image_mut(), action, &frame)
                        };

                        let outputs = match outputs {
                            Ok(o) => o,
                            Err(err) => {
                                let _ = event_tx.send(SessionEvent::SessionStateChanged(
                                    SessionState::Disconnected {
                                        reason: err.to_string(),
                                        clean: false,
                                    },
                                ));
                                break;
                            }
                        };

                        let mut dirty_union: Option<DirtyRect> = None;
                        let mut terminate_reason: Option<String> = None;
                        let mut do_deactivate = false;

                        for out in outputs {
                            match out {
                                ActiveStageOutput::ResponseFrame(bytes) => {
                                    if let Err(err) = framed.write_all(&bytes).await {
                                        terminate_reason = Some(err.to_string());
                                        break;
                                    }
                                }
                                ActiveStageOutput::GraphicsUpdate(rect) => {
                                    let clamped = {
                                        let fb = framebuffer.read().expect("framebuffer lock");
                                        fb.clamp_rect(&rect)
                                    };
                                    if let Some(d) = clamped {
                                        dirty_union = Some(match dirty_union {
                                            Some(prev) => prev.union(d),
                                            None => d,
                                        });
                                    }
                                }
                                ActiveStageOutput::PointerBitmap(ptr) => {
                                    cursor.visible = true;
                                    cursor.width = ptr.width;
                                    cursor.height = ptr.height;
                                    cursor.hotspot_x = ptr.hotspot_x;
                                    cursor.hotspot_y = ptr.hotspot_y;
                                    cursor.rgba_pixels = ptr.bitmap_data.clone();
                                    cursor.emit(&event_tx);
                                }
                                ActiveStageOutput::PointerPosition { x, y } => {
                                    cursor.x = x;
                                    cursor.y = y;
                                    cursor.emit(&event_tx);
                                }
                                ActiveStageOutput::PointerDefault => {
                                    cursor.visible = true;
                                    cursor.width = 0;
                                    cursor.height = 0;
                                    cursor.rgba_pixels.clear();
                                    cursor.emit(&event_tx);
                                }
                                ActiveStageOutput::PointerHidden => {
                                    cursor.visible = false;
                                    cursor.emit(&event_tx);
                                }
                                ActiveStageOutput::DeactivateAll => {
                                    do_deactivate = true;
                                }
                                ActiveStageOutput::Terminate(reason) => {
                                    terminate_reason = Some(reason.description());
                                }
                                ActiveStageOutput::MultitransportRequest(_)
                                | ActiveStageOutput::AutoDetect(_) => {}
                            }
                        }

                        if dirty_union.is_some() || frame_sync {
                            let d = dirty_union.unwrap_or(DirtyRect {
                                x: 0,
                                y: 0,
                                w: cur_width,
                                h: cur_height,
                            });
                            let presentation_ms = session_start.elapsed().as_millis() as u64;
                            let _ = event_tx.send(SessionEvent::FrameUpdated {
                                dirty_x: d.x,
                                dirty_y: d.y,
                                dirty_w: d.w,
                                dirty_h: d.h,
                                width: cur_width,
                                height: cur_height,
                                frame_sync,
                                presentation_ms,
                            });
                        }

                        if let Some(reason) = terminate_reason {
                            let (mut stream, _) = framed.into_inner();
                            let _ = stream.shutdown().await;
                            let _ = event_tx.send(SessionEvent::SessionStateChanged(
                                SessionState::Disconnected { reason, clean: true },
                            ));
                            break;
                        }

                        if do_deactivate {
                            let _ = event_tx.send(SessionEvent::SessionStateChanged(
                                SessionState::Reactivating,
                            ));
                            match run_deactivation_reactivation(
                                &mut framed,
                                &mut connection_result.activation_factory,
                            )
                            .await
                            {
                                Ok((new_w, new_h, new_share_id)) => {
                                    active_stage.set_share_id(new_share_id);
                                    if new_w != cur_width || new_h != cur_height {
                                        cur_width = new_w;
                                        cur_height = new_h;
                                        let mut fb = framebuffer.write().expect("framebuffer lock");
                                        fb.resize(new_w, new_h);
                                        input_ctrl.set_desktop_size(new_w, new_h);
                                    }
                                    let _ = event_tx.send(SessionEvent::SessionStateChanged(
                                        SessionState::Active {
                                            width: cur_width,
                                            height: cur_height,
                                        },
                                    ));
                                }
                                Err(err) => {
                                    let (mut stream, _) = framed.into_inner();
                                    let _ = stream.shutdown().await;
                                    let _ = event_tx.send(SessionEvent::SessionStateChanged(
                                        SessionState::Disconnected {
                                            reason: err.to_string(),
                                            clean: false,
                                        },
                                    ));
                                    break;
                                }
                            }
                        }
                    }
                    Err(err) => {
                        debug!(error = %err, "socket read ended");
                        let _ = event_tx.send(SessionEvent::SessionStateChanged(
                            SessionState::Disconnected {
                                reason: err.to_string(),
                                clean: false,
                            },
                        ));
                        break;
                    }
                }
            }

            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    break;
                };
                match cmd {
                    SessionCommand::SendPointer {
                        x,
                        y,
                        button_mask,
                        down,
                        wheel_delta_v,
                        wheel_delta_h,
                    } => {
                        let events = input_ctrl.pointer_events(
                            x,
                            y,
                            button_mask,
                            down,
                            wheel_delta_v,
                            wheel_delta_h,
                        );
                        if !events.is_empty()
                            && let Err(err) = send_fastpath_input(&mut active_stage, &framebuffer, &mut framed, &events).await
                        {
                            warn!(error = %err, "failed to send pointer input");
                        }
                    }
                    SessionCommand::SendScancode { code, extended, down } => {
                        let events = input_ctrl.scancode_events(code, extended, down);
                        if !events.is_empty()
                            && let Err(err) = send_fastpath_input(&mut active_stage, &framebuffer, &mut framed, &events).await
                        {
                            warn!(error = %err, "failed to send scancode input");
                        }
                    }
                    SessionCommand::SendUnicode { code_unit, down } => {
                        let events = input_ctrl.unicode_events(code_unit, down);
                        if !events.is_empty()
                            && let Err(err) = send_fastpath_input(&mut active_stage, &framebuffer, &mut framed, &events).await
                        {
                            warn!(error = %err, "failed to send unicode input");
                        }
                    }
                    SessionCommand::SetAudioMute(muted) => {
                        if let Ok(mut jb) = audio_buffer.lock() {
                            jb.set_muted(muted);
                        }
                    }
                    SessionCommand::SetAudioVolume(vol) => {
                        if let Ok(mut jb) = audio_buffer.lock() {
                            jb.set_user_volume(vol);
                        }
                    }
                    SessionCommand::Disconnect => {
                        let released = input_ctrl.release_all();
                        if !released.is_empty() {
                            let _ = send_fastpath_input(&mut active_stage, &framebuffer, &mut framed, &released).await;
                        }

                        if let Ok(outputs) = active_stage.graceful_shutdown() {
                            for out in outputs {
                                if let ActiveStageOutput::ResponseFrame(bytes) = out {
                                    let _ = framed.write_all(&bytes).await;
                                }
                            }
                        }

                        // Await server ShutdownDenied -> DPUM (up to 2 seconds)
                        let mut final_reason = "user initiated disconnect".to_owned();
                        let deadline = tokio::time::sleep(Duration::from_secs(2));
                        tokio::pin!(deadline);
                        loop {
                            tokio::select! {
                                _ = &mut deadline => break,
                                pdu = framed.read_pdu() => {
                                    match pdu {
                                        Ok((action, frame)) => {
                                    let res = {
                                        let mut fb = framebuffer.write().expect("framebuffer lock");
                                        active_stage.process(fb.image_mut(), action, &frame)
                                    };
                                    if let Ok(outs) = res {
                                        let mut done = false;
                                        for o in outs {
                                            match o {
                                                ActiveStageOutput::ResponseFrame(bytes) => {
                                                    let _ = framed.write_all(&bytes).await;
                                                }
                                                ActiveStageOutput::Terminate(r) => {
                                                    final_reason = r.description();
                                                    done = true;
                                                }
                                                _ => {}
                                            }
                                        }
                                        if done {
                                            break;
                                        }
                                    }
                                        }
                                        Err(_) => break,
                                    }
                                }
                            }
                        }

                        let (mut stream, _) = framed.into_inner();
                        let _ = stream.shutdown().await;
                        let _ = event_tx.send(SessionEvent::SessionStateChanged(
                            SessionState::Disconnected {
                                reason: final_reason,
                                clean: true,
                            },
                        ));
                        break;
                    }
                    SessionCommand::SubmitCertDecision(_)
                    | SessionCommand::SubmitCredentials(_) => {}
                }
            }

            _ = confirm_notify.notified() => {
                let confirms = {
                    let mut jb = audio_buffer.lock().expect("audio_buffer lock");
                    jb.drain_ready_confirms()
                };
                if !confirms.is_empty() {
                    let count = confirms.len() as u64;
                    let svc_msgs = SvcProcessorMessages::<AerRdpsndProcessor>::new(
                        AerRdpsndProcessor::wrap_wave_confirms(confirms),
                    );
                    match active_stage.process_svc_processor_messages(svc_msgs) {
                        Ok(bytes) => {
                            trace!(count, bytes_len = bytes.len(), "sending playout-paced SNDC_WAVECONFIRM");
                            if let Err(err) = framed.write_all(&bytes).await {
                                warn!(error = %err, "failed writing WaveConfirm");
                            } else if let Ok(mut jb) = audio_buffer.lock() {
                                jb.mark_confirms_sent(count);
                            }
                        }
                        Err(err) => {
                            warn!(error = %err, "failed encoding WaveConfirm");
                        }
                    }
                }
            }
        }
    }
}

async fn send_fastpath_input(
    active_stage: &mut ActiveStage,
    framebuffer: &Arc<RwLock<Framebuffer>>,
    framed: &mut ironrdp_tokio::TokioFramed<ironrdp_tls::TlsStream<tokio::net::TcpStream>>,
    events: &[ironrdp::pdu::input::fast_path::FastPathInputEvent],
) -> Result<(), CoreError> {
    let outs = {
        let mut fb = framebuffer.write().expect("framebuffer lock");
        active_stage
            .process_fastpath_input(fb.image_mut(), events)
            .map_err(|e| CoreError::Session(e.to_string()))?
    };
    for out in outs {
        if let ActiveStageOutput::ResponseFrame(bytes) = out {
            framed.write_all(&bytes).await?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::encode_vec;
    use ironrdp::pdu::fast_path::{EncryptionFlags, Fragmentation};

    #[test]
    fn fastpath_sync_prescan_detects_synchronize_update_code() {
        let update = FastPathUpdatePdu {
            fragmentation: Fragmentation::Single,
            update_code: UpdateCode::Synchronize,
            compression_flags: None,
            compression_type: None,
            data: &[0x00, 0x00],
        };
        let update_bytes = encode_vec(&update).unwrap();
        let header = FastPathHeader::new(EncryptionFlags::empty(), update_bytes.len());
        let mut frame = encode_vec(&header).unwrap();
        frame.extend_from_slice(&update_bytes);

        assert!(scan_fastpath_frame_sync(&frame));
    }
}
