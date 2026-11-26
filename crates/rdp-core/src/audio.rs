use std::collections::VecDeque;
use std::sync::Arc;

use ironrdp::rdpsnd::pdu::WaveConfirmPdu;
use tokio::sync::Notify;

use crate::types::AudioReadStats;

pub const DEFAULT_TARGET_BUFFER_MS: u32 = 60;
pub const DEFAULT_PREBUFFER_MS: u32 = 50;
pub const DEFAULT_MAX_BUFFER_MS: u32 = 150;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioStreamFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
}

impl Default for AudioStreamFormat {
    fn default() -> Self {
        Self {
            sample_rate: 48_000,
            channels: 2,
            bits_per_sample: 16,
        }
    }
}

impl AudioStreamFormat {
    pub fn frame_bytes(self) -> usize {
        let bytes_per_sample = usize::from((self.bits_per_sample / 8).max(1));
        usize::from(self.channels.max(1)) * bytes_per_sample
    }

    pub fn ms_to_frames(self, ms: u32) -> usize {
        ((u64::from(self.sample_rate) * u64::from(ms)) / 1000) as usize
    }

    pub fn frames_to_ms(self, frames: usize) -> u32 {
        if self.sample_rate == 0 {
            return 0;
        }
        ((frames as u64 * 1000) / u64::from(self.sample_rate)) as u32
    }
}

#[derive(Debug, Clone, Copy)]
struct PendingWaveConfirm {
    timestamp: u16,
    block_no: u8,
    end_frame_index: u64,
}

/// Bounded PCM jitter buffer that paces `SNDC_WAVECONFIRM` emission to actual audio sink
/// playback progress and performs drift recovery when queued depth exceeds `max_buffer_ms` (150ms).
#[derive(Debug)]
pub struct AudioJitterBuffer {
    format: AudioStreamFormat,
    pcm_fifo: VecDeque<u8>,
    enqueued_frames: u64,
    popped_frames: u64,
    dropped_frames: u64,
    played_frames: u64,
    pending_confirms: VecDeque<PendingWaveConfirm>,
    ready_confirms: VecDeque<WaveConfirmPdu>,
    confirm_notify: Arc<Notify>,
    target_buffer_ms: u32,
    prebuffer_ms: u32,
    max_buffer_ms: u32,
    prebuffering: bool,
    muted: bool,
    user_volume: f32,
    server_volume_left: u16,
    server_volume_right: u16,
    drops: u64,
    underruns: u64,
    wave_confirms_sent: u64,
    blocks_received: u64,
}

impl AudioJitterBuffer {
    pub fn new(confirm_notify: Arc<Notify>) -> Self {
        Self {
            format: AudioStreamFormat::default(),
            pcm_fifo: VecDeque::with_capacity(48_000 * 4),
            enqueued_frames: 0,
            popped_frames: 0,
            dropped_frames: 0,
            played_frames: 0,
            pending_confirms: VecDeque::new(),
            ready_confirms: VecDeque::new(),
            confirm_notify,
            target_buffer_ms: DEFAULT_TARGET_BUFFER_MS,
            prebuffer_ms: DEFAULT_PREBUFFER_MS,
            max_buffer_ms: DEFAULT_MAX_BUFFER_MS,
            prebuffering: true,
            muted: false,
            user_volume: 1.0,
            server_volume_left: u16::MAX,
            server_volume_right: u16::MAX,
            drops: 0,
            underruns: 0,
            wave_confirms_sent: 0,
            blocks_received: 0,
        }
    }

    pub fn format(&self) -> AudioStreamFormat {
        self.format
    }

    pub fn set_format(&mut self, format: AudioStreamFormat) {
        if self.format != format {
            let had_pending = !self.pending_confirms.is_empty();
            while let Some(front) = self.pending_confirms.pop_front() {
                self.ready_confirms.push_back(WaveConfirmPdu {
                    timestamp: front.timestamp,
                    block_no: front.block_no,
                });
            }
            self.format = format;
            self.pcm_fifo.clear();
            self.enqueued_frames = 0;
            self.popped_frames = 0;
            self.dropped_frames = 0;
            self.played_frames = 0;
            self.prebuffering = true;
            if had_pending {
                self.confirm_notify.notify_one();
            }
        }
    }

    pub fn set_muted(&mut self, muted: bool) {
        self.muted = muted;
    }

    pub fn is_muted(&self) -> bool {
        self.muted
    }

    pub fn set_user_volume(&mut self, volume: f32) {
        self.user_volume = volume.clamp(0.0, 1.0);
    }

    pub fn user_volume(&self) -> f32 {
        self.user_volume
    }

    pub fn set_server_volume(&mut self, left: u16, right: u16) {
        self.server_volume_left = left;
        self.server_volume_right = right;
    }

    pub fn server_volume(&self) -> (u16, u16) {
        (self.server_volume_left, self.server_volume_right)
    }

    pub fn queued_frames(&self) -> usize {
        let fb = self.format.frame_bytes().max(1);
        self.pcm_fifo.len() / fb
    }

    pub fn queued_ms(&self) -> u32 {
        self.format.frames_to_ms(self.queued_frames())
    }

    pub fn drift_ms(&self) -> i64 {
        i64::from(self.queued_ms()) - i64::from(self.target_buffer_ms)
    }

    pub fn blocks_received(&self) -> u64 {
        self.blocks_received
    }

    pub fn wave_confirms_sent(&self) -> u64 {
        self.wave_confirms_sent
    }

    pub fn mark_confirms_sent(&mut self, count: u64) {
        self.wave_confirms_sent += count;
    }

    pub fn drain_ready_confirms(&mut self) -> Vec<WaveConfirmPdu> {
        self.ready_confirms.drain(..).collect()
    }

    /// Enqueues decoded PCM bytes from `SNDC_WAVE2` or `SNDC_WAVE` without sending
    /// an eager `SNDC_WAVECONFIRM`.
    pub fn push_pcm_block(&mut self, timestamp: u16, block_no: u8, pcm_bytes: &[u8]) {
        let frame_bytes = self.format.frame_bytes().max(1);
        let usable_bytes = (pcm_bytes.len() / frame_bytes) * frame_bytes;
        if usable_bytes == 0 {
            return;
        }
        let frames_added = (usable_bytes / frame_bytes) as u64;
        self.pcm_fifo.extend(&pcm_bytes[..usable_bytes]);
        self.enqueued_frames += frames_added;
        self.blocks_received += 1;
        self.pending_confirms.push_back(PendingWaveConfirm {
            timestamp,
            block_no,
            end_frame_index: self.enqueued_frames,
        });
    }

    /// Reads PCM frames into `out` and advances the playout clock by `frames_played_since_last_read`.
    ///
    /// - Releases `WaveConfirmPdu` items only for blocks whose frames have actually been played
    ///   (or dropped during >150ms drift catch-up trim so the server's in-flight window never stalls).
    /// - Performs bounded catch-up trimming when queued duration exceeds `max_buffer_ms` (150ms).
    pub fn read_pcm_frames(
        &mut self,
        out: &mut [u8],
        frames_played_since_last_read: usize,
    ) -> AudioReadStats {
        let frame_bytes = self.format.frame_bytes().max(1);
        let max_frames = self.format.ms_to_frames(self.max_buffer_ms);
        let target_frames = self.format.ms_to_frames(self.target_buffer_ms);
        let prebuffer_frames = self.format.ms_to_frames(self.prebuffer_ms);

        // 1. Advance playout progress (clamped to actual frames previously handed to sink).
        let prev_played = self.played_frames;
        if frames_played_since_last_read > 0 {
            let max_playable = self.popped_frames.saturating_sub(self.played_frames);
            let advance = (frames_played_since_last_read as u64).min(max_playable);
            self.played_frames += advance;
        }
        let step1_credited = self.played_frames - prev_played;

        // 2. Bounded jitter-buffer catch-up trim when queued > 150ms.
        let queued_now = self.queued_frames();
        if queued_now > max_frames && max_frames > target_frames {
            let trim_frames = queued_now - target_frames;
            let trim_bytes = trim_frames * frame_bytes;
            let actual_bytes = trim_bytes.min(self.pcm_fifo.len());
            self.pcm_fifo.drain(..actual_bytes);
            let actual_frames = (actual_bytes / frame_bytes) as u64;
            self.dropped_frames += actual_frames;
            self.drops += actual_frames;
        }

        // 3. Release confirms for all blocks played or dropped up to `confirmed_horizon`.
        let confirmed_horizon = self.dropped_frames.saturating_add(self.played_frames);
        let mut newly_ready = false;
        while let Some(front) = self.pending_confirms.front().copied() {
            if front.end_frame_index <= confirmed_horizon {
                self.pending_confirms.pop_front();
                self.ready_confirms.push_back(WaveConfirmPdu {
                    timestamp: front.timestamp,
                    block_no: front.block_no,
                });
                newly_ready = true;
            } else {
                break;
            }
        }

        // 4. Read requested frames from FIFO (or silence while prebuffering / on underrun).
        let req_frames = out.len() / frame_bytes;
        let req_bytes = req_frames * frame_bytes;
        let out_slice = &mut out[..req_bytes];

        let queued_after_trim = self.queued_frames();
        if self.prebuffering {
            if queued_after_trim >= prebuffer_frames {
                self.prebuffering = false;
            } else {
                out_slice.fill(0);
                // Even if `frames_played_since_last_read` was passed alongside the first read,
                // keep confirms locked while prebuffering.
                if newly_ready {
                    self.confirm_notify.notify_one();
                }
                return self.stats(0);
            }
        }

        let avail_frames = self.queued_frames();
        let read_frames = req_frames.min(avail_frames);
        let read_bytes = read_frames * frame_bytes;

        for byte in out_slice[..read_bytes].iter_mut() {
            *byte = self.pcm_fifo.pop_front().unwrap_or(0);
        }
        if read_bytes < req_bytes {
            out_slice[read_bytes..].fill(0);
            if req_frames > 0 && read_frames < req_frames {
                self.underruns += 1;
            }
        }
        self.popped_frames += read_frames as u64;

        // If caller models synchronous playback (passed `frames_played_since_last_read > 0` beyond
        // what Step 1 already credited against prior reads), credit remaining playback up to
        // `popped_frames` so both pre-credit and post-credit sink loops stay aligned.
        let remaining_advance = (frames_played_since_last_read as u64).saturating_sub(step1_credited);
        if remaining_advance > 0 {
            let new_played = self
                .played_frames
                .saturating_add(remaining_advance)
                .min(self.popped_frames);
            if new_played > self.played_frames {
                self.played_frames = new_played;
                let confirmed_horizon = self.dropped_frames.saturating_add(self.played_frames);
                while let Some(front) = self.pending_confirms.front().copied() {
                    if front.end_frame_index <= confirmed_horizon {
                        self.pending_confirms.pop_front();
                        self.ready_confirms.push_back(WaveConfirmPdu {
                            timestamp: front.timestamp,
                            block_no: front.block_no,
                        });
                        newly_ready = true;
                    } else {
                        break;
                    }
                }
            }
        }

        // Apply mute / volume scaling on the read PCM samples.
        self.apply_gain(&mut out_slice[..read_bytes]);

        if newly_ready {
            self.confirm_notify.notify_one();
        }

        self.stats(read_frames)
    }

    fn apply_gain(&self, pcm: &mut [u8]) {
        if self.muted || self.user_volume <= 0.0 {
            pcm.fill(0);
            return;
        }
        let srv_l = f32::from(self.server_volume_left) / f32::from(u16::MAX);
        let srv_r = f32::from(self.server_volume_right) / f32::from(u16::MAX);
        let gain_l = (self.user_volume * srv_l).clamp(0.0, 1.0);
        let gain_r = (self.user_volume * srv_r).clamp(0.0, 1.0);
        if (gain_l - 1.0).abs() < 1e-4 && (gain_r - 1.0).abs() < 1e-4 {
            return;
        }
        if self.format.bits_per_sample == 16 {
            let channels = usize::from(self.format.channels.max(1));
            let (chunks, _) = pcm.as_chunks_mut::<2>();
            for (idx, chunk) in chunks.iter_mut().enumerate() {
                let sample = i16::from_le_bytes(*chunk);
                let ch = idx % channels;
                let g = if ch == 0 { gain_l } else { gain_r };
                let scaled = (f32::from(sample) * g)
                    .round()
                    .clamp(f32::from(i16::MIN), f32::from(i16::MAX)) as i16;
                *chunk = scaled.to_le_bytes();
            }
        }
    }

    pub fn stats(&self, frames_read: usize) -> AudioReadStats {
        AudioReadStats {
            frames_read,
            queued_ms: self.queued_ms(),
            drift_ms: self.drift_ms(),
            drops: self.drops,
            underruns: self.underruns,
            wave_confirms_sent: self.wave_confirms_sent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pcm_20ms_48k_stereo(val: i16) -> Vec<u8> {
        let frames = 960;
        let mut out = Vec::with_capacity(frames * 4);
        let b = val.to_le_bytes();
        for _ in 0..(frames * 2) {
            out.extend_from_slice(&b);
        }
        out
    }

    #[test]
    fn no_eager_wave_confirm_until_played() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        let block = pcm_20ms_48k_stereo(1000);
        for i in 0..5u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        assert_eq!(buf.queued_ms(), 100);
        assert!(buf.drain_ready_confirms().is_empty(), "must NOT emit confirms on enqueue");

        let mut out = vec![0u8; 960 * 4];
        for _ in 0..5 {
            let stats = buf.read_pcm_frames(&mut out, 960);
            assert_eq!(stats.frames_read, 960);
        }
        let confirms = buf.drain_ready_confirms();
        assert_eq!(confirms.len(), 5);
        assert_eq!(confirms[0].block_no, 0);
        assert_eq!(confirms[4].block_no, 4);
    }

    #[test]
    fn burst_over_150ms_trims_to_target_and_flushes_dropped_confirms() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        let block = pcm_20ms_48k_stereo(1000);
        for i in 0..15u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        assert_eq!(buf.queued_ms(), 300);

        let mut out = vec![0u8; 960 * 4];
        let stats = buf.read_pcm_frames(&mut out, 960);
        assert!(stats.drops > 0);
        assert!(stats.queued_ms <= 60);

        let mut confirms = buf.drain_ready_confirms();
        for _ in 0..3 {
            let _ = buf.read_pcm_frames(&mut out, 960);
            confirms.extend(buf.drain_ready_confirms());
        }
        assert_eq!(confirms.len(), 15, "all 15 blocks (dropped + played) must confirm");
    }

    #[test]
    fn mute_silences_output() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        buf.set_muted(true);
        let block = pcm_20ms_48k_stereo(12_000);
        for i in 0..3u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        let mut out = vec![0xAAu8; 960 * 4];
        let stats = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(stats.frames_read, 960);
        assert!(out.iter().all(|&b| b == 0));
    }

    #[test]
    fn async_post_credit_sink_does_not_double_credit() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        let block = pcm_20ms_48k_stereo(1500);
        for i in 0..4u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        assert_eq!(buf.queued_ms(), 80);

        let mut out = vec![0u8; 960 * 4];
        // Call 1: sink pulls 960 frames, 0 previously played -> no confirms yet
        let s1 = buf.read_pcm_frames(&mut out, 0);
        assert_eq!(s1.frames_read, 960);
        assert!(buf.drain_ready_confirms().is_empty());

        // Call 2: sink reports 960 frames played from Call 1, pulls block 1 -> ONLY block 0 confirms!
        let s2 = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(s2.frames_read, 960);
        let c2 = buf.drain_ready_confirms();
        assert_eq!(c2.len(), 1, "must confirm ONLY block 0, not block 1");
        assert_eq!(c2[0].block_no, 0);

        // Call 3: confirms ONLY block 1
        let s3 = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(s3.frames_read, 960);
        let c3 = buf.drain_ready_confirms();
        assert_eq!(c3.len(), 1);
        assert_eq!(c3[0].block_no, 1);

        // Call 4: confirms ONLY block 2
        let s4 = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(s4.frames_read, 960);
        let c4 = buf.drain_ready_confirms();
        assert_eq!(c4.len(), 1);
        assert_eq!(c4[0].block_no, 2);

        // Final tail credit: confirms block 3
        let s5 = buf.read_pcm_frames(&mut [], 960);
        assert_eq!(s5.frames_read, 0);
        let c5 = buf.drain_ready_confirms();
        assert_eq!(c5.len(), 1);
        assert_eq!(c5[0].block_no, 3);
    }

    #[test]
    fn async_sink_with_over150ms_trim_preserves_pacing() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        let block = pcm_20ms_48k_stereo(1000);
        for i in 0..15u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        assert_eq!(buf.queued_ms(), 300);

        let mut out = vec![0u8; 960 * 4];
        // Call 1 (async 0 played): trims 12 blocks (0..=11) down to 60ms (blocks 12,13,14),
        // pops block 12 (unplayed) -> confirms ONLY 0..=11.
        let s1 = buf.read_pcm_frames(&mut out, 0);
        assert_eq!(s1.frames_read, 960);
        assert_eq!(s1.drops, 12 * 960);
        let c1 = buf.drain_ready_confirms();
        assert_eq!(c1.len(), 12);
        assert_eq!(c1.last().unwrap().block_no, 11);

        // Call 2: reports 960 played (block 12), pops block 13 -> confirms ONLY block 12
        let s2 = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(s2.frames_read, 960);
        let c2 = buf.drain_ready_confirms();
        assert_eq!(c2.len(), 1);
        assert_eq!(c2[0].block_no, 12);

        // Call 3: confirms ONLY block 13, pops block 14
        let s3 = buf.read_pcm_frames(&mut out, 960);
        assert_eq!(s3.frames_read, 960);
        let c3 = buf.drain_ready_confirms();
        assert_eq!(c3.len(), 1);
        assert_eq!(c3[0].block_no, 13);

        // Tail credit: confirms block 14
        let _ = buf.read_pcm_frames(&mut [], 960);
        let c4 = buf.drain_ready_confirms();
        assert_eq!(c4.len(), 1);
        assert_eq!(c4[0].block_no, 14);
    }

    #[test]
    fn set_format_flushes_pending_confirms_on_mid_session_switch() {
        let notify = Arc::new(Notify::new());
        let mut buf = AudioJitterBuffer::new(notify);
        let block = pcm_20ms_48k_stereo(500);
        for i in 0..3u8 {
            buf.push_pcm_block(u16::from(i) * 20, i, &block);
        }
        assert!(buf.drain_ready_confirms().is_empty());

        buf.set_format(AudioStreamFormat {
            sample_rate: 44_100,
            channels: 2,
            bits_per_sample: 16,
        });
        assert_eq!(buf.queued_frames(), 0);
        let flushed = buf.drain_ready_confirms();
        assert_eq!(flushed.len(), 3);
        assert_eq!(flushed[0].block_no, 0);
        assert_eq!(flushed[2].block_no, 2);
    }
}
