use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use ironrdp::core::{Decode as _, ReadCursor, impl_as_any};
use ironrdp::pdu::PduResult;
use ironrdp::pdu::gcc::ChannelName;
use ironrdp::rdpsnd::pdu::{
    AudioFormat, ClientAudioOutputPdu, ServerAudioFormatPdu, ServerAudioOutputPdu, TrainingPdu,
    Version, VolumePdu, Wave2Pdu, WaveFormat, WavePdu,
};
use ironrdp::svc::{CompressionCondition, SvcMessage, SvcProcessor, SvcServerProcessor};
use tracing::{debug, trace};

use crate::ServerMetricsInner;

#[derive(Debug)]
pub struct TestRdpsndProcessor {
    version: Version,
    sample_rate: u32,
    channels: u16,
    metrics: Arc<Mutex<ServerMetricsInner>>,
    ready: bool,
    negotiated_format_no: u16,
    in_flight: HashMap<(u16, u8), Instant>,
    pending_training: VecDeque<(u16, Instant)>,
    next_block_no: u8,
    phase_samples: u64,
    session_start: Instant,
}

impl TestRdpsndProcessor {
    pub const CHANNEL_NAME: ChannelName = ChannelName::from_static(b"rdpsnd\0\0");

    pub fn new(
        rdpsnd_version: u16,
        sample_rate: u32,
        channels: u16,
        metrics: Arc<Mutex<ServerMetricsInner>>,
        session_start: Instant,
    ) -> Self {
        let version = match rdpsnd_version {
            2 => Version::V2,
            5 => Version::V5,
            6 => Version::V6,
            _ => Version::V8,
        };
        Self {
            version,
            sample_rate,
            channels,
            metrics,
            ready: false,
            negotiated_format_no: 0,
            in_flight: HashMap::new(),
            pending_training: VecDeque::new(),
            next_block_no: 0,
            phase_samples: 0,
            session_start,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }

    pub fn server_formats(&self) -> Vec<AudioFormat> {
        let block_align = self.channels * 2;
        let avg_bytes = self.sample_rate * u32::from(block_align);
        vec![AudioFormat {
            format: WaveFormat::PCM,
            n_channels: self.channels,
            n_samples_per_sec: self.sample_rate,
            n_avg_bytes_per_sec: avg_bytes,
            n_block_align: block_align,
            bits_per_sample: 16,
            data: None,
        }]
    }

    pub fn build_training_msg(&mut self, payload_len: usize) -> SvcMessage {
        let ts = (self.session_start.elapsed().as_millis() & 0xFFFF) as u16;
        self.pending_training.push_back((ts, Instant::now()));
        ServerAudioOutputPdu::Training(TrainingPdu {
            timestamp: ts,
            data: vec![0xA5u8; payload_len],
        })
        .into()
    }

    pub fn build_volume_msg(&self, left: u16, right: u16) -> SvcMessage {
        ServerAudioOutputPdu::Volume(VolumePdu {
            volume_left: left,
            volume_right: right,
        })
        .into()
    }

    /// Generates one PCM sine wave block (`chunk_ms` ms at `audio_hz`) and encodes it as
    /// `SNDC_WAVE2` (`wVersion >= 8`) or `SNDC_WAVE` (`wVersion < 8`).
    pub fn build_tone_wave_msg(&mut self, audio_hz: u32, chunk_ms: u32) -> SvcMessage {
        let frames = ((u64::from(self.sample_rate) * u64::from(chunk_ms)) / 1000).max(1) as usize;
        let mut pcm = Vec::with_capacity(frames * usize::from(self.channels) * 2);
        let freq = f64::from(audio_hz.max(1));
        let sr = f64::from(self.sample_rate.max(1));

        for _ in 0..frames {
            let t = self.phase_samples as f64 / sr;
            let sample_f = (2.0 * std::f64::consts::PI * freq * t).sin() * 14_000.0;
            let sample = sample_f.round() as i16;
            let bytes = sample.to_le_bytes();
            for _ in 0..self.channels {
                pcm.extend_from_slice(&bytes);
            }
            self.phase_samples += 1;
        }

        let elapsed_ms = self.session_start.elapsed().as_millis() as u32;
        let ts = (elapsed_ms & 0xFFFF) as u16;
        let block_no = self.next_block_no;
        self.next_block_no = self.next_block_no.wrapping_add(1);

        self.in_flight.insert((ts, block_no), Instant::now());
        if let Ok(mut m) = self.metrics.lock() {
            m.audio_blocks_sent += 1;
            m.in_flight_window = self.in_flight.len() as u64;
            m.last_audio_timestamp_ms = Some(elapsed_ms);
        }

        if self.version >= Version::V8 {
            ServerAudioOutputPdu::Wave2(Wave2Pdu {
                timestamp: ts,
                format_no: self.negotiated_format_no,
                block_no,
                audio_timestamp: elapsed_ms,
                data: pcm.into(),
            })
            .into()
        } else {
            ServerAudioOutputPdu::Wave(WavePdu {
                timestamp: ts,
                format_no: self.negotiated_format_no,
                block_no,
                data: pcm.into(),
            })
            .into()
        }
    }
}

impl_as_any!(TestRdpsndProcessor);

impl SvcProcessor for TestRdpsndProcessor {
    fn channel_name(&self) -> ChannelName {
        Self::CHANNEL_NAME
    }

    fn compression_condition(&self) -> CompressionCondition {
        CompressionCondition::Never
    }

    fn start(&mut self) -> PduResult<Vec<SvcMessage>> {
        let pdu = ServerAudioOutputPdu::AudioFormat(ServerAudioFormatPdu {
            version: self.version,
            formats: self.server_formats(),
        });
        Ok(vec![pdu.into()])
    }

    fn process(&mut self, payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
        let pdu = ClientAudioOutputPdu::decode(&mut ReadCursor::new(payload))
            .map_err(|e| ironrdp::pdu::decode_err!(e))?;
        trace!(?pdu, "test server rdpsnd received client PDU");

        match pdu {
            ClientAudioOutputPdu::AudioFormat(cf) => {
                if let Some(idx) = cf.formats.iter().position(|f| {
                    f.format == WaveFormat::PCM
                        && f.n_samples_per_sec == self.sample_rate
                        && f.n_channels == self.channels
                }) {
                    self.negotiated_format_no = idx as u16;
                } else {
                    self.negotiated_format_no = 0;
                }
                self.ready = true;
                let msg = self.build_training_msg(0);
                Ok(vec![msg])
            }
            ClientAudioOutputPdu::QualityMode(_) => Ok(Vec::new()),
            ClientAudioOutputPdu::TrainingConfirm(tc) => {
                if let Some((_, sent_at)) = self
                    .pending_training
                    .iter()
                    .position(|(ts, _)| *ts == tc.timestamp)
                    .and_then(|pos| self.pending_training.remove(pos))
                {
                    let rtt = sent_at.elapsed().as_millis() as u64;
                    if let Ok(mut m) = self.metrics.lock() {
                        m.last_training_rtt_ms = Some(rtt);
                    }
                }
                Ok(Vec::new())
            }
            ClientAudioOutputPdu::WaveConfirm(wc) => {
                if let Some(sent_at) = self.in_flight.remove(&(wc.timestamp, wc.block_no)) {
                    let lat = sent_at.elapsed().as_millis() as u64;
                    if let Ok(mut m) = self.metrics.lock() {
                        m.audio_blocks_confirmed += 1;
                        m.last_confirm_latency_ms = Some(lat);
                        m.in_flight_window = self.in_flight.len() as u64;
                    }
                } else {
                    debug!(?wc, "unmatched WaveConfirm");
                }
                Ok(Vec::new())
            }
        }
    }
}

impl SvcServerProcessor for TestRdpsndProcessor {}
