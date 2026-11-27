use std::sync::{Arc, Mutex};

use ironrdp_core::{
    Decode as _, Encode, EncodeResult, ReadCursor, WriteCursor, impl_as_any,
};
use ironrdp_dvc::{
    DrdynvcClient, DvcChannelListener, DvcClientProcessor, DvcEncode, DvcMessage, DvcProcessor,
    DynamicChannelId, encode_dvc_messages,
};
use ironrdp_pdu::PduResult;
use ironrdp_pdu::gcc::ChannelName;
use ironrdp_rdpsnd::pdu::{
    AudioFormat, AudioFormatFlags, ClientAudioFormatPdu, ClientAudioOutputPdu, QualityMode,
    QualityModePdu, ServerAudioFormatPdu, ServerAudioOutputPdu, TrainingConfirmPdu, TrainingPdu,
    Version, WaveConfirmPdu, WaveFormat, WaveInfoPdu,
};
use ironrdp_svc::{
    ChannelFlags, CompressionCondition, SvcClientProcessor, SvcMessage, SvcProcessor,
};
use tokio::sync::mpsc;
use tracing::{debug, trace, warn};

use crate::audio::{AudioJitterBuffer, AudioStreamFormat};
use crate::types::SessionEvent;

pub const AUDIO_PLAYBACK_DVC_NAME: &str = "AUDIO_PLAYBACK_DVC";
pub const AUDIO_PLAYBACK_LOSSY_DVC_NAME: &str = "AUDIO_PLAYBACK_LOSSY_DVC";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ActiveAudioRoute {
    #[default]
    StaticSvc,
    Dvc {
        channel_id: u32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RdpsndPhase {
    Start,
    Active,
    Stopped,
}

#[derive(Debug, Clone)]
struct PendingSplitWave {
    timestamp: u16,
    format_no: u16,
    block_no: u8,
    first4: [u8; 4],
    remaining_bytes: usize,
}

#[derive(Debug, Clone)]
struct RdpsndDvcMessage(ClientAudioOutputPdu);

impl Encode for RdpsndDvcMessage {
    fn encode(&self, dst: &mut WriteCursor<'_>) -> EncodeResult<()> {
        self.0.encode(dst)
    }

    fn name(&self) -> &'static str {
        self.0.name()
    }

    fn size(&self) -> usize {
        self.0.size()
    }
}

impl DvcEncode for RdpsndDvcMessage {}

#[derive(Debug)]
pub struct AerRdpsndCore {
    phase: RdpsndPhase,
    route: ActiveAudioRoute,
    server_format: Option<ServerAudioFormatPdu>,
    negotiated_formats: Vec<AudioFormat>,
    active_format: Option<AudioStreamFormat>,
    pending_split_wave: Option<PendingSplitWave>,
    jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
    event_tx: mpsc::UnboundedSender<SessionEvent>,
    client_version: Version,
    training_count: u64,
    last_training_pack_size: u16,
}

impl AerRdpsndCore {
    pub fn new(
        jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
        event_tx: mpsc::UnboundedSender<SessionEvent>,
    ) -> Self {
        Self {
            phase: RdpsndPhase::Start,
            route: ActiveAudioRoute::StaticSvc,
            server_format: None,
            negotiated_formats: Vec::new(),
            active_format: None,
            pending_split_wave: None,
            jitter_buffer,
            event_tx,
            client_version: Version::V8,
            training_count: 0,
            last_training_pack_size: 0,
        }
    }

    pub fn active_route(&self) -> ActiveAudioRoute {
        self.route
    }

    fn reset_for_dvc_open(&mut self, channel_id: u32) {
        self.phase = RdpsndPhase::Start;
        self.route = ActiveAudioRoute::Dvc { channel_id };
        self.server_format = None;
        self.negotiated_formats.clear();
        self.pending_split_wave = None;
    }

    fn on_dvc_close(&mut self, channel_id: u32) {
        if self.route == (ActiveAudioRoute::Dvc { channel_id }) {
            self.pending_split_wave = None;
            self.route = ActiveAudioRoute::StaticSvc;
        }
    }

    fn negotiate_formats(server_formats: &[AudioFormat]) -> Vec<AudioFormat> {
        let preferred = AerRdpsndProcessor::preferred_pcm_formats();
        let mut common = Vec::new();

        // 1. Prefer deterministic 48kHz / 44.1kHz 16-bit PCM formats offered by the server.
        for pref in &preferred {
            if let Some(matched) = server_formats.iter().find(|sf| {
                sf.format == WaveFormat::PCM
                    && sf.n_channels == pref.n_channels
                    && sf.n_samples_per_sec == pref.n_samples_per_sec
                    && sf.bits_per_sample == pref.bits_per_sample
            }) && !common.contains(matched)
            {
                common.push(matched.clone());
            }
        }

        // 2. Also accept any other standard 8/16-bit 1/2-ch PCM format offered by the server.
        for sf in server_formats {
            if sf.format == WaveFormat::PCM
                && (sf.bits_per_sample == 16 || sf.bits_per_sample == 8)
                && (sf.n_channels == 1 || sf.n_channels == 2)
                && sf.n_samples_per_sec >= 8_000
                && !common.contains(sf)
            {
                common.push(sf.clone());
            }
        }

        // 3. Also accept 32-bit IEEE_FLOAT 1/2-ch if offered by the server (converted to s16le on arrival).
        for sf in server_formats {
            if sf.format == WaveFormat::IEEE_FLOAT
                && sf.bits_per_sample == 32
                && (sf.n_channels == 1 || sf.n_channels == 2)
                && sf.n_samples_per_sec >= 8_000
                && !common.contains(sf)
            {
                common.push(sf.clone());
            }
        }

        if common.is_empty() && server_formats.is_empty() {
            common = preferred;
        }
        common
    }

    fn handle_server_formats(
        &mut self,
        af: ServerAudioFormatPdu,
        source_route: ActiveAudioRoute,
    ) -> Vec<ClientAudioOutputPdu> {
        let negotiated_version = if af.version < Version::V8 {
            af.version
        } else {
            Version::V8
        };
        self.route = source_route;
        self.client_version = negotiated_version;
        let formats = Self::negotiate_formats(&af.formats);
        debug!(
            route = ?source_route,
            server_version = ?af.version,
            server_format_count = af.formats.len(),
            negotiated_count = formats.len(),
            "RDPSND format negotiation"
        );
        self.negotiated_formats = formats.clone();
        self.server_format = Some(af);
        self.pending_split_wave = None;
        self.phase = RdpsndPhase::Active;

        let mut msgs = vec![ClientAudioOutputPdu::AudioFormat(ClientAudioFormatPdu {
            version: negotiated_version,
            flags: AudioFormatFlags::ALIVE | AudioFormatFlags::VOLUME,
            formats,
            volume_left: u16::MAX,
            volume_right: u16::MAX,
            pitch: 0x0001_0000,
            dgram_port: 0,
        })];

        if negotiated_version >= Version::V6 {
            msgs.push(ClientAudioOutputPdu::QualityMode(QualityModePdu {
                quality_mode: QualityMode::High,
            }));
        }

        msgs
    }

    fn handle_training(&mut self, pdu: &TrainingPdu, wire_pack_size: Option<u16>) -> Vec<ClientAudioOutputPdu> {
        self.training_count += 1;
        // MS-RDPEA 2.2.3.2: wPackSize in Training Confirm MUST echo the exact wPackSize sent by the server.
        // Note: `ironrdp::rdpsnd::pdu::TrainingPdu::decode` subtracts 8 (SNDPROLOG + SNDTRAINING headers)
        // when `wPackSize != 0`, so reconstruct or use the exact wire `wPackSize` from `payload[6..8]`.
        let pack_size: u16 = wire_pack_size.unwrap_or_else(|| {
            if pdu.data.is_empty() {
                0
            } else {
                pdu.data.len().saturating_add(8).min(usize::from(u16::MAX)) as u16
            }
        });
        self.last_training_pack_size = pack_size;
        vec![ClientAudioOutputPdu::TrainingConfirm(TrainingConfirmPdu {
            timestamp: pdu.timestamp,
            pack_size,
        })]
    }

    fn resolve_audio_format(&self, format_no: u16) -> AudioFormat {
        let idx = usize::from(format_no);
        self.negotiated_formats
            .get(idx)
            .cloned()
            .or_else(|| {
                self.server_format
                    .as_ref()
                    .and_then(|sf| sf.formats.get(idx).cloned())
            })
            .unwrap_or_else(|| AerRdpsndProcessor::preferred_pcm_formats().remove(0))
    }

    fn enqueue_wave_pcm(&mut self, timestamp: u16, format_no: u16, block_no: u8, raw_data: &[u8]) {
        let fmt = self.resolve_audio_format(format_no);
        let normalized_pcm: Vec<u8>;
        let (stream_fmt, pcm_slice) = if fmt.format == WaveFormat::PCM && fmt.bits_per_sample == 8 {
            normalized_pcm = raw_data
                .iter()
                .flat_map(|&sample| {
                    let s16 = (i16::from(sample) - 128) << 8;
                    s16.to_le_bytes()
                })
                .collect();
            (
                AudioStreamFormat {
                    sample_rate: fmt.n_samples_per_sec,
                    channels: fmt.n_channels.max(1),
                    bits_per_sample: 16,
                },
                normalized_pcm.as_slice(),
            )
        } else if fmt.format == WaveFormat::IEEE_FLOAT && fmt.bits_per_sample == 32 {
            let (chunks, _) = raw_data.as_chunks::<4>();
            normalized_pcm = chunks
                .iter()
                .flat_map(|bytes| {
                    let f = f32::from_le_bytes(*bytes);
                    let clamped = if f.is_finite() { f.clamp(-1.0, 1.0) } else { 0.0 };
                    let s16 = (clamped * 32767.0).round() as i16;
                    s16.to_le_bytes()
                })
                .collect();
            (
                AudioStreamFormat {
                    sample_rate: fmt.n_samples_per_sec,
                    channels: fmt.n_channels.max(1),
                    bits_per_sample: 16,
                },
                normalized_pcm.as_slice(),
            )
        } else if fmt.format == WaveFormat::PCM {
            (
                AudioStreamFormat {
                    sample_rate: fmt.n_samples_per_sec,
                    channels: fmt.n_channels.max(1),
                    bits_per_sample: fmt.bits_per_sample.max(16),
                },
                raw_data,
            )
        } else {
            warn!(format = %fmt.format, "ignoring unsupported non-PCM rdpsnd wave block");
            return;
        };

        let format_changed = self.active_format != Some(stream_fmt);
        if format_changed {
            self.active_format = Some(stream_fmt);
            let _ = self.event_tx.send(SessionEvent::AudioStreamOpened {
                sample_rate: stream_fmt.sample_rate,
                channels: stream_fmt.channels,
                bits_per_sample: stream_fmt.bits_per_sample,
            });
        }

        if let Ok(mut guard) = self.jitter_buffer.lock() {
            if format_changed {
                guard.set_format(stream_fmt);
            }
            guard.push_pcm_block(timestamp, block_no, pcm_slice);
        }
    }

    fn looks_like_rdpsnd_pdu(payload: &[u8]) -> bool {
        if payload.len() < 4 || payload[1] != 0x00 {
            return false;
        }
        let msg_type = payload[0];
        if !matches!(msg_type, 0x01 | 0x03 | 0x04 | 0x06 | 0x07 | 0x08 | 0x09 | 0x0D) {
            return false;
        }
        let body_size = usize::from(u16::from_le_bytes([payload[2], payload[3]]));
        4 + body_size == payload.len()
    }

    fn normalize_server_formats_version(payload: &[u8]) -> Option<Vec<u8>> {
        // SNDPROLOG (4) + dwFlags (4) + dwVolume (4) + dwPitch (4) + wDGramPort (2)
        // + wNumberOfFormats (2) + cLastBlockConfirmed (1) + wVersion (2) + bPad (1) = 24 bytes.
        if payload.len() < 24 || payload[0] != 0x07 {
            return None;
        }
        let raw_ver = u16::from_le_bytes([payload[21], payload[22]]);
        if matches!(raw_ver, 0x02 | 0x05 | 0x06 | 0x08) {
            return None;
        }
        let mapped: u16 = if raw_ver > 0x08 {
            0x08
        } else if raw_ver >= 0x06 {
            0x06
        } else if raw_ver >= 0x05 {
            0x05
        } else {
            0x02
        };
        let mut patched = payload.to_vec();
        let bytes = mapped.to_le_bytes();
        patched[21] = bytes[0];
        patched[22] = bytes[1];
        Some(patched)
    }

    fn process_pdu_bytes(
        &mut self,
        payload: &[u8],
        source_route: ActiveAudioRoute,
        lossy: bool,
    ) -> PduResult<Vec<ClientAudioOutputPdu>> {
        if lossy {
            if self.phase != RdpsndPhase::Active {
                return Ok(Vec::new());
            }
            if let Ok(ServerAudioOutputPdu::Wave2(w2)) =
                ServerAudioOutputPdu::decode(&mut ReadCursor::new(payload))
            {
                self.enqueue_wave_pcm(w2.timestamp, w2.format_no, w2.block_no, &w2.data);
            }
            return Ok(Vec::new());
        }

        if let Some(pending) = self.pending_split_wave.as_ref() {
            let expected_wave_len = 4usize.saturating_add(pending.remaining_bytes);
            let is_expected_sndwave =
                payload.len() == expected_wave_len && payload.first().copied() == Some(0x00);

            if !is_expected_sndwave && Self::looks_like_rdpsnd_pdu(payload) {
                if let Ok(pdu) = ServerAudioOutputPdu::decode(&mut ReadCursor::new(payload))
                    && matches!(
                        pdu,
                        ServerAudioOutputPdu::AudioFormat(_)
                            | ServerAudioOutputPdu::Close
                            | ServerAudioOutputPdu::Wave2(_)
                    )
                {
                    self.pending_split_wave = None;
                }
            } else if !is_expected_sndwave
                && payload.len() == 16
                && payload[0] == 0x02
                && payload[1] == 0x00
            {
                self.pending_split_wave = None;
            } else if let Some(pending) = self.pending_split_wave.take() {
                if payload.len() >= 4 {
                    let mut combined = Vec::with_capacity(4 + payload.len().saturating_sub(4));
                    combined.extend_from_slice(&pending.first4);
                    let take_len = pending.remaining_bytes.min(payload.len() - 4);
                    combined.extend_from_slice(&payload[4..4 + take_len]);
                    self.route = source_route;
                    self.enqueue_wave_pcm(
                        pending.timestamp,
                        pending.format_no,
                        pending.block_no,
                        &combined,
                    );
                }
                return Ok(Vec::new());
            }
        }

        if payload.len() >= 16 && payload[0] == 0x02 && payload[1] == 0x00 {
            let body_size = u16::from_le_bytes([payload[2], payload[3]]);
            let mut cursor = ReadCursor::new(&payload[4..16]);
            if let Ok(info) = WaveInfoPdu::decode(&mut cursor) {
                let total_audio_bytes = usize::from(body_size).saturating_sub(8);
                if payload.len() == 4 + usize::from(body_size) && total_audio_bytes > 4 {
                    self.route = source_route;
                    self.enqueue_wave_pcm(
                        info.timestamp,
                        info.format_no,
                        info.block_no,
                        &payload[12..12 + total_audio_bytes],
                    );
                    return Ok(Vec::new());
                } else if total_audio_bytes <= 4 {
                    self.route = source_route;
                    self.enqueue_wave_pcm(
                        info.timestamp,
                        info.format_no,
                        info.block_no,
                        &info.data[..total_audio_bytes],
                    );
                    return Ok(Vec::new());
                } else if payload.len() == 16 {
                    let remaining_bytes = total_audio_bytes - 4;
                    self.pending_split_wave = Some(PendingSplitWave {
                        timestamp: info.timestamp,
                        format_no: info.format_no,
                        block_no: info.block_no,
                        first4: info.data,
                        remaining_bytes,
                    });
                    return Ok(Vec::new());
                }
            }
        }

        let wire_training_pack_size = if payload.len() >= 8 && payload[0] == 0x06 {
            Some(u16::from_le_bytes([payload[6], payload[7]]))
        } else {
            None
        };

        let normalized_buf = Self::normalize_server_formats_version(payload);
        let decode_slice = normalized_buf.as_deref().unwrap_or(payload);

        let pdu = match ServerAudioOutputPdu::decode(&mut ReadCursor::new(decode_slice)) {
            Ok(pdu) => pdu,
            Err(err) => {
                warn!(error = %err, len = payload.len(), "ignoring unrecognized RDPSND PDU");
                return Ok(Vec::new());
            }
        };
        trace!(?pdu, phase = ?self.phase, route = ?source_route, "rdpsnd server PDU");

        match (self.phase, pdu) {
            (_, ServerAudioOutputPdu::AudioFormat(af)) => {
                Ok(self.handle_server_formats(af, source_route))
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Training(t)) => {
                self.route = source_route;
                Ok(self.handle_training(&t, wire_training_pack_size))
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Wave2(w2)) => {
                self.route = source_route;
                self.enqueue_wave_pcm(w2.timestamp, w2.format_no, w2.block_no, &w2.data);
                Ok(Vec::new())
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Wave(w)) => {
                self.route = source_route;
                let take = usize::from(w.audio_length).min(4);
                self.enqueue_wave_pcm(w.timestamp, w.format_no, w.block_no, &w.data_prefix[..take]);
                Ok(Vec::new())
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Volume(vol)) => {
                if let Ok(mut guard) = self.jitter_buffer.lock() {
                    guard.set_server_volume(vol.volume_left, vol.volume_right);
                }
                let _ = self.event_tx.send(SessionEvent::AudioVolumeChanged {
                    left: vol.volume_left,
                    right: vol.volume_right,
                });
                Ok(Vec::new())
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Pitch(_)) => Ok(Vec::new()),
            (RdpsndPhase::Active, ServerAudioOutputPdu::Close) => Ok(Vec::new()),
            (_, ServerAudioOutputPdu::CryptKey(_) | ServerAudioOutputPdu::WaveEncrypt(_)) => {
                Ok(Vec::new())
            }
            (phase, other) => {
                debug!(?phase, ?other, "ignoring unexpected rdpsnd PDU");
                if phase == RdpsndPhase::Start {
                    self.phase = RdpsndPhase::Stopped;
                }
                Ok(Vec::new())
            }
        }
    }
}

/// Custom `rdpsnd` static virtual channel processor built on `ironrdp::rdpsnd::pdu::*`,
/// sharing state with `AUDIO_PLAYBACK_DVC` (`AerRdpsndDvcProcessor`) for Windows 10/11.
#[derive(Debug, Clone)]
pub struct AerRdpsndProcessor {
    core: Arc<Mutex<AerRdpsndCore>>,
}

impl AerRdpsndProcessor {
    pub const CHANNEL_NAME: ChannelName = ChannelName::from_static(b"rdpsnd\0\0");

    pub fn new(
        jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
        event_tx: mpsc::UnboundedSender<SessionEvent>,
    ) -> Self {
        Self {
            core: Arc::new(Mutex::new(AerRdpsndCore::new(jitter_buffer, event_tx))),
        }
    }

    pub fn attach_to_drdynvc(
        drdynvc: DrdynvcClient,
        jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
        event_tx: mpsc::UnboundedSender<SessionEvent>,
    ) -> (Self, DrdynvcClient, Arc<Mutex<AerRdpsndCore>>) {
        let core = Arc::new(Mutex::new(AerRdpsndCore::new(jitter_buffer, event_tx)));
        let svc = Self {
            core: Arc::clone(&core),
        };
        let drdynvc = drdynvc
            .with_listener(AerRdpsndDvcListener {
                core: Arc::clone(&core),
                lossy: false,
            })
            .with_listener(AerRdpsndDvcListener {
                core: Arc::clone(&core),
                lossy: true,
            });
        (svc, drdynvc, core)
    }

    pub fn new_shared(
        jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
        event_tx: mpsc::UnboundedSender<SessionEvent>,
    ) -> (Self, DrdynvcClient, Arc<Mutex<AerRdpsndCore>>) {
        Self::attach_to_drdynvc(DrdynvcClient::new(), jitter_buffer, event_tx)
    }

    pub fn preferred_pcm_formats() -> Vec<AudioFormat> {
        vec![
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 192_000,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            },
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 44_100,
                n_avg_bytes_per_sec: 176_400,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            },
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 1,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 96_000,
                n_block_align: 2,
                bits_per_sample: 16,
                data: None,
            },
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 1,
                n_samples_per_sec: 44_100,
                n_avg_bytes_per_sec: 88_200,
                n_block_align: 2,
                bits_per_sample: 16,
                data: None,
            },
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 22_050,
                n_avg_bytes_per_sec: 88_200,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            },
            AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 1,
                n_samples_per_sec: 16_000,
                n_avg_bytes_per_sec: 32_000,
                n_block_align: 2,
                bits_per_sample: 16,
                data: None,
            },
        ]
    }

    pub fn training_count(&self) -> u64 {
        self.core
            .lock()
            .map(|c| c.training_count)
            .unwrap_or(0)
    }

    pub fn last_training_pack_size(&self) -> u16 {
        self.core
            .lock()
            .map(|c| c.last_training_pack_size)
            .unwrap_or(0)
    }

    pub fn wrap_wave_confirms(confirms: Vec<WaveConfirmPdu>) -> Vec<SvcMessage> {
        confirms
            .into_iter()
            .map(|pdu| ClientAudioOutputPdu::WaveConfirm(pdu).into())
            .collect()
    }

    pub fn wrap_dvc_wave_confirms(
        channel_id: u32,
        confirms: Vec<WaveConfirmPdu>,
    ) -> EncodeResult<Vec<SvcMessage>> {
        let dvc_msgs: Vec<DvcMessage> = confirms
            .into_iter()
            .map(|pdu| -> DvcMessage {
                Box::new(RdpsndDvcMessage(ClientAudioOutputPdu::WaveConfirm(pdu)))
            })
            .collect();
        encode_dvc_messages(channel_id, dvc_msgs, ChannelFlags::empty())
    }
}

impl_as_any!(AerRdpsndProcessor);

impl SvcProcessor for AerRdpsndProcessor {
    fn channel_name(&self) -> ChannelName {
        Self::CHANNEL_NAME
    }

    fn compression_condition(&self) -> CompressionCondition {
        CompressionCondition::Never
    }

    fn process(&mut self, payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
        let mut guard = self
            .core
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let replies = guard.process_pdu_bytes(payload, ActiveAudioRoute::StaticSvc, false)?;
        Ok(replies.into_iter().map(SvcMessage::from).collect())
    }
}

impl SvcClientProcessor for AerRdpsndProcessor {}

struct AerRdpsndDvcListener {
    core: Arc<Mutex<AerRdpsndCore>>,
    lossy: bool,
}

impl DvcChannelListener for AerRdpsndDvcListener {
    fn channel_name(&self) -> &str {
        if self.lossy {
            AUDIO_PLAYBACK_LOSSY_DVC_NAME
        } else {
            AUDIO_PLAYBACK_DVC_NAME
        }
    }

    fn create(&mut self, _channel_id: DynamicChannelId) -> Option<Box<dyn DvcClientProcessor>> {
        Some(Box::new(AerRdpsndDvcProcessor {
            core: Arc::clone(&self.core),
            lossy: self.lossy,
        }))
    }
}

#[derive(Debug)]
pub struct AerRdpsndDvcProcessor {
    core: Arc<Mutex<AerRdpsndCore>>,
    lossy: bool,
}

impl_as_any!(AerRdpsndDvcProcessor);

impl DvcProcessor for AerRdpsndDvcProcessor {
    fn channel_name(&self) -> &str {
        if self.lossy {
            AUDIO_PLAYBACK_LOSSY_DVC_NAME
        } else {
            AUDIO_PLAYBACK_DVC_NAME
        }
    }

    fn start(&mut self, channel_id: u32) -> PduResult<Vec<DvcMessage>> {
        debug!(channel_id, lossy = self.lossy, "AUDIO_PLAYBACK_DVC channel started");
        if !self.lossy {
            let mut guard = self.core.lock().unwrap_or_else(|e| e.into_inner());
            guard.reset_for_dvc_open(channel_id);
        }
        Ok(Vec::new())
    }

    fn process(&mut self, channel_id: u32, payload: &[u8]) -> PduResult<Vec<DvcMessage>> {
        let mut guard = self.core.lock().unwrap_or_else(|e| e.into_inner());
        let replies = guard.process_pdu_bytes(
            payload,
            ActiveAudioRoute::Dvc { channel_id },
            self.lossy,
        )?;
        Ok(replies
            .into_iter()
            .map(|pdu| -> DvcMessage { Box::new(RdpsndDvcMessage(pdu)) })
            .collect())
    }

    fn close(&mut self, channel_id: u32) {
        debug!(channel_id, lossy = self.lossy, "AUDIO_PLAYBACK_DVC channel closed");
        if !self.lossy {
            let mut guard = self.core.lock().unwrap_or_else(|e| e.into_inner());
            guard.on_dvc_close(channel_id);
        }
    }
}

impl DvcClientProcessor for AerRdpsndDvcProcessor {}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_core::encode_vec;
    use ironrdp_rdpsnd::pdu::{VolumePdu, Wave2Pdu, WavePdu};
    use ironrdp_svc::StaticVirtualChannel;
    use tokio::sync::Notify;

    fn make_proc() -> (
        StaticVirtualChannel,
        Arc<Mutex<AudioJitterBuffer>>,
        mpsc::UnboundedReceiver<SessionEvent>,
    ) {
        let notify = Arc::new(Notify::new());
        let jb = Arc::new(Mutex::new(AudioJitterBuffer::new(notify)));
        let (tx, rx) = mpsc::unbounded_channel();
        let proc = AerRdpsndProcessor::new(Arc::clone(&jb), tx);
        (StaticVirtualChannel::new(proc), jb, rx)
    }

    #[test]
    fn multichunk_svc_reassembly_and_no_eager_confirm() {
        let (mut svc, jb, mut rx) = make_proc();

        let server_fmt = ServerAudioOutputPdu::AudioFormat(ServerAudioFormatPdu {
            version: Version::V8,
            formats: vec![AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 192_000,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            }],
        });

        let fmt_chunks = StaticVirtualChannel::chunkify(vec![server_fmt.into()]).unwrap();
        assert_eq!(fmt_chunks.len(), 1);
        let reply = svc.process(fmt_chunks[0].filled()).unwrap();
        assert_eq!(reply.len(), 2, "expected ClientAudioFormat + QualityMode");

        // Build >1600 byte Wave2 payload (e.g. 40ms @ 48kHz stereo = 7680 bytes -> 5 chunks!)
        let pcm = vec![0x2Au8; 7680];
        let wave2 = ServerAudioOutputPdu::Wave2(Wave2Pdu {
            timestamp: 100,
            format_no: 0,
            block_no: 7,
            audio_timestamp: 100,
            data: pcm.clone().into(),
        });
        let chunks = StaticVirtualChannel::chunkify(vec![wave2.into()]).unwrap();
        assert!(chunks.len() > 1, "payload must span multiple CHANNEL_PDU_HEADER chunks");

        for (idx, chunk) in chunks.iter().enumerate() {
            let out = svc.process(chunk.filled()).unwrap();
            assert!(out.is_empty(), "chunk {idx} must not emit eager WaveConfirm");
        }

        let guard = jb.lock().unwrap();
        assert_eq!(guard.blocks_received(), 1);
        assert_eq!(guard.queued_ms(), 40);
        assert!(matches!(rx.try_recv().unwrap(), SessionEvent::AudioStreamOpened { .. }));
    }

    #[test]
    fn legacy_wave_pdu_and_split_wave_decode_identically() {
        let (mut svc, jb, _rx) = make_proc();
        let server_fmt = ServerAudioOutputPdu::AudioFormat(ServerAudioFormatPdu {
            version: Version::V5,
            formats: vec![AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 192_000,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            }],
        });
        let fmt_chunks = StaticVirtualChannel::chunkify(vec![server_fmt.into()]).unwrap();
        let reply = svc.process(fmt_chunks[0].filled()).unwrap();
        assert_eq!(reply.len(), 1, "v5 must not send QualityMode");

        let pcm: Vec<u8> = (0..3840usize).map(|i| (i % 251) as u8).collect();
        let mut inline_wave_msg = Vec::with_capacity(12 + pcm.len());
        inline_wave_msg.extend_from_slice(&[0x02, 0x00]);
        inline_wave_msg.extend_from_slice(&((8 + pcm.len()) as u16).to_le_bytes());
        inline_wave_msg.extend_from_slice(
            &encode_vec(&WaveInfoPdu {
                timestamp: 50,
                format_no: 0,
                block_no: 3,
                data: [pcm[0], pcm[1], pcm[2], pcm[3]],
            })
            .unwrap(),
        );
        inline_wave_msg.extend_from_slice(&pcm[4..]);
        let chunks = StaticVirtualChannel::chunkify(vec![inline_wave_msg.into()]).unwrap();
        for chunk in chunks {
            assert!(svc.process(chunk.filled()).unwrap().is_empty());
        }

        // Also test split WaveInfo + SndWave message sequence
        let mut wave_info_msg = Vec::with_capacity(16);
        wave_info_msg.extend_from_slice(&[0x02, 0x00]); // SNDC_WAVE + pad
        wave_info_msg.extend_from_slice(&((8 + pcm.len()) as u16).to_le_bytes());
        let info_pdu = WaveInfoPdu {
            timestamp: 70,
            format_no: 0,
            block_no: 4,
            data: [pcm[0], pcm[1], pcm[2], pcm[3]],
        };
        wave_info_msg.extend_from_slice(&encode_vec(&info_pdu).unwrap());

        let mut wave_body_msg = vec![0u8; 4]; // 4-byte bPad
        wave_body_msg.extend_from_slice(&pcm[4..]);

        let c1 = StaticVirtualChannel::chunkify(vec![wave_info_msg.into()]).unwrap();
        for c in c1 {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }
        let c2 = StaticVirtualChannel::chunkify(vec![wave_body_msg.into()]).unwrap();
        for c in c2 {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }

        // Push a third block via ServerAudioOutputPdu::Wave + SndWave body so total queued = 60ms >= prebuffer_ms (50ms)
        let wave3 = ServerAudioOutputPdu::Wave(WavePdu {
            timestamp: 90,
            format_no: 0,
            block_no: 5,
            data_prefix: [pcm[0], pcm[1], pcm[2], pcm[3]],
            audio_length: pcm.len() as u16,
        });
        let mut wave3_body = vec![0u8; 4];
        wave3_body.extend_from_slice(&pcm[4..]);
        for chunk in StaticVirtualChannel::chunkify(vec![wave3.into(), wave3_body.into()]).unwrap() {
            assert!(svc.process(chunk.filled()).unwrap().is_empty());
        }

        let mut guard = jb.lock().unwrap();
        assert_eq!(guard.blocks_received(), 3);
        assert_eq!(guard.queued_ms(), 60);

        let mut out1 = vec![0u8; pcm.len()];
        let mut out2 = vec![0u8; pcm.len()];
        let mut out3 = vec![0u8; pcm.len()];
        let s1 = guard.read_pcm_frames(&mut out1, 960);
        let s2 = guard.read_pcm_frames(&mut out2, 960);
        let s3 = guard.read_pcm_frames(&mut out3, 960);
        assert_eq!(s1.frames_read, 960);
        assert_eq!(s2.frames_read, 960);
        assert_eq!(s3.frames_read, 960);
        assert_eq!(out1, pcm);
        assert_eq!(out2, pcm);
        assert_eq!(out3, pcm);
    }

    #[test]
    fn split_wave_survives_interleaved_volume_and_training() {
        let (mut svc, jb, _rx) = make_proc();
        let server_fmt = ServerAudioOutputPdu::AudioFormat(ServerAudioFormatPdu {
            version: Version::V5,
            formats: vec![AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 192_000,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            }],
        });
        for c in StaticVirtualChannel::chunkify(vec![server_fmt.into()]).unwrap() {
            let _ = svc.process(c.filled()).unwrap();
        }

        let pcm: Vec<u8> = (0..3840usize).map(|i| ((i * 7 + 3) % 251) as u8).collect();
        let mut wave_info_msg = Vec::with_capacity(16);
        wave_info_msg.extend_from_slice(&[0x02, 0x00]); // SNDC_WAVE + pad
        wave_info_msg.extend_from_slice(&((8 + pcm.len()) as u16).to_le_bytes());
        let info_pdu = WaveInfoPdu {
            timestamp: 120,
            format_no: 0,
            block_no: 9,
            data: [pcm[0], pcm[1], pcm[2], pcm[3]],
        };
        wave_info_msg.extend_from_slice(&encode_vec(&info_pdu).unwrap());

        for c in StaticVirtualChannel::chunkify(vec![wave_info_msg.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }

        // Interleave SNDC_SETVOLUME and SNDC_TRAINING before SndWave part 2 arrives
        let vol_pdu = ServerAudioOutputPdu::Volume(VolumePdu {
            volume_left: 0x4000,
            volume_right: 0x8000,
        });
        for c in StaticVirtualChannel::chunkify(vec![vol_pdu.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }
        assert_eq!(jb.lock().unwrap().server_volume(), (0x4000, 0x8000));

        let train_pdu = ServerAudioOutputPdu::Training(TrainingPdu {
            timestamp: 333,
            data: vec![0x5Au8; 16],
        });
        let mut train_replies = Vec::new();
        for c in StaticVirtualChannel::chunkify(vec![train_pdu.into()]).unwrap() {
            train_replies.extend(svc.process(c.filled()).unwrap());
        }
        assert_eq!(train_replies.len(), 1, "interleaved Training must emit TrainingConfirm");

        // Now deliver SndWave part 2 (4-byte bPad + remaining PCM)
        let mut wave_body_msg = vec![0u8; 4];
        wave_body_msg.extend_from_slice(&pcm[4..]);
        for c in StaticVirtualChannel::chunkify(vec![wave_body_msg.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }

        assert_eq!(jb.lock().unwrap().blocks_received(), 1);
        assert_eq!(jb.lock().unwrap().queued_ms(), 20);

        // Verify SNDC_CLOSE clears an aborted split wave so a subsequent PDU decodes cleanly
        let mut aborted_info = Vec::with_capacity(16);
        aborted_info.extend_from_slice(&[0x02, 0x00]);
        aborted_info.extend_from_slice(&((8 + pcm.len()) as u16).to_le_bytes());
        aborted_info.extend_from_slice(
            &encode_vec(&WaveInfoPdu {
                timestamp: 140,
                format_no: 0,
                block_no: 10,
                data: [1, 2, 3, 4],
            })
            .unwrap(),
        );
        for c in StaticVirtualChannel::chunkify(vec![aborted_info.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }
        for c in StaticVirtualChannel::chunkify(vec![ServerAudioOutputPdu::Close.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }
        let next_vol = ServerAudioOutputPdu::Volume(VolumePdu {
            volume_left: 0xFFFF,
            volume_right: 0xFFFF,
        });
        for c in StaticVirtualChannel::chunkify(vec![next_vol.into()]).unwrap() {
            assert!(svc.process(c.filled()).unwrap().is_empty());
        }
        assert_eq!(jb.lock().unwrap().server_volume(), (0xFFFF, 0xFFFF));

        // Verify intact PCM from the earlier split wave
        let mut jb_guard = jb.lock().unwrap();
        jb_guard.set_server_volume(u16::MAX, u16::MAX);
        for b in 1..=2u8 {
            jb_guard.push_pcm_block(120 + u16::from(b) * 20, 9 + b, &pcm);
        }
        let mut out = vec![0u8; pcm.len()];
        let st = jb_guard.read_pcm_frames(&mut out, 960);
        assert_eq!(st.frames_read, 960);
        assert_eq!(out, pcm);
    }

    #[test]
    fn training_confirm_echoes_exact_wire_pack_size_and_dvc_listener_reopens_cleanly() {
        use ironrdp_dvc::pdu::{
            CapabilitiesRequestPdu, CapsVersion, ClosePdu, CreateRequestPdu, DataPdu,
            DrdynvcDataPdu, DrdynvcServerPdu,
        };

        let notify = Arc::new(Notify::new());
        let jb = Arc::new(Mutex::new(AudioJitterBuffer::new(notify)));
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (svc_proc, drdynvc, core) = AerRdpsndProcessor::new_shared(Arc::clone(&jb), tx);
        let mut drdynvc_svc = StaticVirtualChannel::new(drdynvc);

        // 1. Simulate Windows 11 DRDYNVC Caps + DYNVC_CREATE_REQ (Session 4 -> close -> Session 1).
        let caps_req = DrdynvcServerPdu::Capabilities(
            CapabilitiesRequestPdu::new(CapsVersion::V2, None),
        );
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(caps_req)]).unwrap() {
            let _ = drdynvc_svc.process(c.filled()).unwrap();
        }

        // Open channel_id = 1 (Session 4), then close, then reopen channel_id = 2 (Session 1).
        let create1 = DrdynvcServerPdu::Create(CreateRequestPdu::new(
            1,
            AUDIO_PLAYBACK_DVC_NAME.to_owned(),
        ));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(create1)]).unwrap() {
            let reply = drdynvc_svc.process(c.filled()).unwrap();
            assert!(!reply.is_empty(), "DYNVC_CREATE_REQ #1 must succeed");
        }
        assert_eq!(
            core.lock().unwrap().active_route(),
            ActiveAudioRoute::Dvc { channel_id: 1 }
        );

        let close1 = DrdynvcServerPdu::Close(ClosePdu::new(1));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(close1)]).unwrap() {
            let _ = drdynvc_svc.process(c.filled()).unwrap();
        }

        let create2 = DrdynvcServerPdu::Create(CreateRequestPdu::new(
            2,
            AUDIO_PLAYBACK_DVC_NAME.to_owned(),
        ));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(create2)]).unwrap() {
            let reply = drdynvc_svc.process(c.filled()).unwrap();
            assert!(!reply.is_empty(), "DYNVC_CREATE_REQ #2 after session arbitration must succeed");
        }
        assert_eq!(
            core.lock().unwrap().active_route(),
            ActiveAudioRoute::Dvc { channel_id: 2 }
        );

        // 2. Send SNDC_FORMATS over DVC channel 2 and verify pitch == 0x0001_0000.
        let fmt_bytes = encode_vec(&ServerAudioOutputPdu::AudioFormat(ServerAudioFormatPdu {
            version: Version::V8,
            formats: vec![AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 44_100,
                n_avg_bytes_per_sec: 176_400,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            }],
        }))
        .unwrap();
        let dvc_fmt = DrdynvcServerPdu::Data(DrdynvcDataPdu::Data(
            DataPdu::new(2, fmt_bytes),
        ));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(dvc_fmt)]).unwrap() {
            let replies = drdynvc_svc.process(c.filled()).unwrap();
            assert!(!replies.is_empty());
        }

        // 3. Send non-empty SNDC_TRAINING (1016 data bytes -> wire wPackSize == 1024) and verify exact 1024 echo!
        let train_bytes = encode_vec(&ServerAudioOutputPdu::Training(TrainingPdu {
            timestamp: 0x1234,
            data: vec![0xAAu8; 1016],
        }))
        .unwrap();
        assert_eq!(u16::from_le_bytes([train_bytes[6], train_bytes[7]]), 1024);
        let dvc_train = DrdynvcServerPdu::Data(DrdynvcDataPdu::Data(
            DataPdu::new(2, train_bytes),
        ));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(dvc_train)]).unwrap() {
            let replies = drdynvc_svc.process(c.filled()).unwrap();
            assert!(!replies.is_empty());
        }
        assert_eq!(svc_proc.last_training_pack_size(), 1024);

        // 4. Send Wave2 over DVC channel 2 and verify PCM arrives & AudioStreamOpened fires at 44100 Hz.
        let pcm_20ms = vec![0x11u8; 882 * 4];
        let wave2_bytes = encode_vec(&ServerAudioOutputPdu::Wave2(Wave2Pdu {
            timestamp: 200,
            format_no: 0,
            block_no: 1,
            audio_timestamp: 200,
            data: pcm_20ms.into(),
        }))
        .unwrap();
        let dvc_wave = DrdynvcServerPdu::Data(DrdynvcDataPdu::Data(
            DataPdu::new(2, wave2_bytes),
        ));
        for c in StaticVirtualChannel::chunkify(vec![SvcMessage::from(dvc_wave)]).unwrap() {
            let _ = drdynvc_svc.process(c.filled()).unwrap();
        }
        assert_eq!(jb.lock().unwrap().blocks_received(), 1);
        assert!(matches!(
            rx.try_recv().unwrap(),
            SessionEvent::AudioStreamOpened {
                sample_rate: 44_100,
                channels: 2,
                bits_per_sample: 16
            }
        ));
    }
}
