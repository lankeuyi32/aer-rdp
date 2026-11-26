use std::sync::{Arc, Mutex};

use ironrdp::core::{Decode as _, ReadCursor, impl_as_any};
use ironrdp::pdu::{PduResult, decode_err};
use ironrdp::pdu::gcc::ChannelName;
use ironrdp::rdpsnd::pdu::{
    AudioFormat, AudioFormatFlags, ClientAudioFormatPdu, ClientAudioOutputPdu, QualityMode,
    QualityModePdu, ServerAudioFormatPdu, ServerAudioOutputPdu, TrainingConfirmPdu, TrainingPdu,
    Version, WaveConfirmPdu, WaveFormat, WaveInfoPdu,
};
use ironrdp::svc::{CompressionCondition, SvcClientProcessor, SvcMessage, SvcProcessor};
use tokio::sync::mpsc;
use tracing::{debug, trace, warn};

use crate::audio::{AudioJitterBuffer, AudioStreamFormat};
use crate::types::SessionEvent;

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

/// Custom `rdpsnd` static virtual channel processor built on `ironrdp::rdpsnd::pdu::*`.
///
/// Unlike `ironrdp_rdpsnd::client::Rdpsnd`:
/// - Supports both `SNDC_WAVE2` (v8+) and legacy `SNDC_WAVE` (`WaveInfo` + `Wave`, v<8).
/// - Does NOT emit `SNDC_WAVECONFIRM` eagerly on arrival; instead enqueues PCM into
///   `AudioJitterBuffer`, which releases `WaveConfirmPdu` only as frames are played or
///   trimmed during drift recovery.
#[derive(Debug)]
pub struct AerRdpsndProcessor {
    phase: RdpsndPhase,
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

impl AerRdpsndProcessor {
    pub const CHANNEL_NAME: ChannelName = ChannelName::from_static(b"rdpsnd\0\0");

    pub fn new(
        jitter_buffer: Arc<Mutex<AudioJitterBuffer>>,
        event_tx: mpsc::UnboundedSender<SessionEvent>,
    ) -> Self {
        Self {
            phase: RdpsndPhase::Start,
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
        self.training_count
    }

    pub fn last_training_pack_size(&self) -> u16 {
        self.last_training_pack_size
    }

    pub fn wrap_wave_confirms(confirms: Vec<WaveConfirmPdu>) -> Vec<SvcMessage> {
        confirms
            .into_iter()
            .map(|pdu| ClientAudioOutputPdu::WaveConfirm(pdu).into())
            .collect()
    }

    fn negotiate_formats(server_formats: &[AudioFormat]) -> Vec<AudioFormat> {
        let preferred = Self::preferred_pcm_formats();
        let mut common = Vec::new();

        // First add formats matching our priority list (preserving deterministic preference order).
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

        // Also accept any other standard 8/16-bit 1/2-ch PCM format offered by the server.
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

        if common.is_empty() {
            // Fallback: advertise our preferred list per MS-RDPEA so server knows our capabilities.
            common = preferred;
        }
        common
    }

    fn handle_server_formats(&mut self, af: ServerAudioFormatPdu) -> PduResult<Vec<SvcMessage>> {
        let negotiated_version = if af.version < Version::V8 {
            af.version
        } else {
            Version::V8
        };
        self.client_version = negotiated_version;
        let formats = Self::negotiate_formats(&af.formats);
        self.negotiated_formats = formats.clone();
        self.server_format = Some(af);
        self.phase = RdpsndPhase::Active;

        let mut msgs: Vec<SvcMessage> = vec![
            ClientAudioOutputPdu::AudioFormat(ClientAudioFormatPdu {
                version: negotiated_version,
                flags: AudioFormatFlags::ALIVE | AudioFormatFlags::VOLUME,
                formats,
                volume_left: u16::MAX,
                volume_right: u16::MAX,
                pitch: 0,
                dgram_port: 0,
            })
            .into(),
        ];

        if negotiated_version >= Version::V6 {
            msgs.push(
                ClientAudioOutputPdu::QualityMode(QualityModePdu {
                    quality_mode: QualityMode::High,
                })
                .into(),
            );
        }

        Ok(msgs)
    }

    fn handle_training(&mut self, pdu: &TrainingPdu) -> PduResult<Vec<SvcMessage>> {
        self.training_count += 1;
        let pack_size: u16 = pdu.data.len().min(usize::from(u16::MAX)) as u16;
        self.last_training_pack_size = pack_size;
        Ok(vec![
            ClientAudioOutputPdu::TrainingConfirm(TrainingConfirmPdu {
                timestamp: pdu.timestamp,
                pack_size,
            })
            .into(),
        ])
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
            .unwrap_or_else(|| Self::preferred_pcm_formats().remove(0))
    }

    fn enqueue_wave_pcm(&mut self, timestamp: u16, format_no: u16, block_no: u8, raw_data: &[u8]) {
        let fmt = self.resolve_audio_format(format_no);
        if fmt.format != WaveFormat::PCM {
            warn!(format = %fmt.format, "ignoring non-PCM rdpsnd wave block");
            return;
        }

        // Normalize 8-bit unsigned PCM to 16-bit signed LE PCM if needed; 16-bit PCM stays native.
        let normalized_pcm: Vec<u8>;
        let (stream_fmt, pcm_slice) = if fmt.bits_per_sample == 8 {
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
        } else {
            (
                AudioStreamFormat {
                    sample_rate: fmt.n_samples_per_sec,
                    channels: fmt.n_channels.max(1),
                    bits_per_sample: fmt.bits_per_sample.max(16),
                },
                raw_data,
            )
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
                // Fall through to normal ServerAudioOutputPdu dispatch while keeping
                // `pending_split_wave` intact for interleaved Volume / Pitch / Training.
            } else if !is_expected_sndwave
                && payload.len() == 16
                && payload[0] == 0x02
                && payload[1] == 0x00
            {
                // New split WaveInfo supersedes aborted previous one; fall through to WaveInfo branch.
                self.pending_split_wave = None;
            } else if let Some(pending) = self.pending_split_wave.take() {
                // Split SNDC_WAVE part 2: 4-byte bPad + remaining PCM payload.
                if payload.len() >= 4 {
                    let mut combined = Vec::with_capacity(4 + payload.len().saturating_sub(4));
                    combined.extend_from_slice(&pending.first4);
                    let take_len = pending.remaining_bytes.min(payload.len() - 4);
                    combined.extend_from_slice(&payload[4..4 + take_len]);
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

        // Check for split WaveInfo-only payload (`msgType == 0x02` and payload.len() == 16)
        // before delegating to `ServerAudioOutputPdu::decode`, which expects combined WaveInfo+SndWave.
        if payload.len() == 16 && payload[0] == 0x02 {
            let body_size = u16::from_le_bytes([payload[2], payload[3]]);
            let mut cursor = ReadCursor::new(&payload[4..]);
            if let Ok(info) = WaveInfoPdu::decode(&mut cursor) {
                let remaining_bytes = usize::from(body_size).saturating_sub(12);
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

        let pdu = ServerAudioOutputPdu::decode(&mut ReadCursor::new(payload)).map_err(|e| decode_err!(e))?;
        trace!(?pdu, phase = ?self.phase, "rdpsnd server PDU");

        match (self.phase, pdu) {
            (_, ServerAudioOutputPdu::AudioFormat(af)) => self.handle_server_formats(af),
            (RdpsndPhase::Active, ServerAudioOutputPdu::Training(t)) => self.handle_training(&t),
            (RdpsndPhase::Active, ServerAudioOutputPdu::Wave2(w2)) => {
                self.enqueue_wave_pcm(w2.timestamp, w2.format_no, w2.block_no, &w2.data);
                // Critical: NO eager SNDC_WAVECONFIRM!
                Ok(Vec::new())
            }
            (RdpsndPhase::Active, ServerAudioOutputPdu::Wave(w)) => {
                self.enqueue_wave_pcm(w.timestamp, w.format_no, w.block_no, &w.data);
                // Critical: NO eager SNDC_WAVECONFIRM!
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

impl SvcClientProcessor for AerRdpsndProcessor {}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::encode_vec;
    use ironrdp::rdpsnd::pdu::{VolumePdu, Wave2Pdu, WavePdu};
    use ironrdp::svc::StaticVirtualChannel;
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
        let wave = ServerAudioOutputPdu::Wave(WavePdu {
            timestamp: 50,
            format_no: 0,
            block_no: 3,
            data: pcm.clone().into(),
        });
        let chunks = StaticVirtualChannel::chunkify(vec![wave.into()]).unwrap();
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

        // Push a third block (Wave2/Wave) so total queued = 60ms >= prebuffer_ms (50ms)
        let wave3 = ServerAudioOutputPdu::Wave(WavePdu {
            timestamp: 90,
            format_no: 0,
            block_no: 5,
            data: pcm.clone().into(),
        });
        for chunk in StaticVirtualChannel::chunkify(vec![wave3.into()]).unwrap() {
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
}
