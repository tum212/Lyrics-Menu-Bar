use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

use crate::haptics::HapticEngine;

pub const FFT_SIZE: usize = 4096;
pub const HALF_LEN: usize = FFT_SIZE / 2;
pub const MAX_BANDS: usize = 128;

struct DspState {
    circular_buf: Vec<f32>,
    circular_idx: usize,
    input_buf: Vec<f32>,
    spectrum_out: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    hann_window: Vec<f32>,
    magnitudes: Vec<f32>,
    raw_bands: [f32; MAX_BANDS],
    band_gains: [f32; MAX_BANDS],
    spectrum_buf: [f32; MAX_BANDS],
    fft: Arc<dyn RealToComplex<f32>>,
}

impl DspState {
    fn new() -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);
        let scratch = fft.make_scratch_vec();
        let spectrum_out = fft.make_output_vec();
        let input_buf = fft.make_input_vec();

        let mut hann_window = vec![0.0_f32; FFT_SIZE];
        let denom = (FFT_SIZE - 1) as f32;
        for (i, w) in hann_window.iter_mut().enumerate() {
            *w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (i as f32) / denom).cos());
        }

        Self {
            circular_buf: vec![0.0; FFT_SIZE],
            circular_idx: 0,
            input_buf,
            spectrum_out,
            scratch,
            hann_window,
            magnitudes: vec![0.0; HALF_LEN],
            raw_bands: [0.0; MAX_BANDS],
            band_gains: [0.05; MAX_BANDS],
            spectrum_buf: [0.0; MAX_BANDS],
            fft,
        }
    }

    fn zero_state(&mut self) {
        self.circular_buf.fill(0.0);
        self.circular_idx = 0;
        self.raw_bands.fill(0.0);
        self.band_gains.fill(0.05);
        self.spectrum_buf.fill(0.0);
    }
}

pub struct AudioDspEngine {
    dsp: Mutex<DspState>,
    pub band_count: AtomicUsize,
    pub has_live_audio: AtomicBool,
    needs_dsp_reset: AtomicBool,
    published_amps: [AtomicU32; MAX_BANDS],
    bar_heights: Mutex<[f32; MAX_BANDS]>,
}

impl AudioDspEngine {
    pub fn new() -> Self {
        let published_amps = std::array::from_fn(|_| AtomicU32::new(0.05_f32.to_bits()));
        Self {
            dsp: Mutex::new(DspState::new()),
            band_count: AtomicUsize::new(14),
            has_live_audio: AtomicBool::new(false),
            needs_dsp_reset: AtomicBool::new(false),
            published_amps,
            bar_heights: Mutex::new([2.5; MAX_BANDS]),
        }
    }

    pub fn update_band_count(&self, count: usize) {
        let clamped = count.clamp(1, MAX_BANDS);
        // Fast-path Relaxed load prevents 60 FPS cross-core cache-line bouncing
        if self.band_count.load(Ordering::Relaxed) == clamped {
            return;
        }
        let prev = self.band_count.swap(clamped, Ordering::AcqRel);
        if prev == clamped {
            return;
        }
        for i in 0..clamped {
            self.published_amps[i].store(0.01_f32.to_bits(), Ordering::Relaxed);
        }
        self.needs_dsp_reset.store(true, Ordering::Release);
        let mut bars = self.bar_heights.lock().unwrap_or_else(|e| e.into_inner());
        bars[..clamped].fill(2.5);
    }

    pub fn reset(&self) {
        self.has_live_audio.store(false, Ordering::Release);
        self.needs_dsp_reset.store(true, Ordering::Release);
        for slot in &self.published_amps {
            slot.store(0.0_f32.to_bits(), Ordering::Relaxed);
        }
        let mut bars = self.bar_heights.lock().unwrap_or_else(|e| e.into_inner());
        bars.fill(2.5);
    }

    #[inline]
    fn clean_sample(s: f32) -> f32 {
        if s.is_finite() {
            s.clamp(-8.0, 8.0)
        } else {
            0.0
        }
    }

    /// Zero-allocation real-time audio callback processor.
    /// Returns immediately if mutex is contended so the CoreAudio IOProc thread never blocks.
    pub fn process_pcm(
        &self,
        left: &[f32],
        right: Option<&[f32]>,
        channels: usize,
        sample_rate: f32,
        output_host_time: u64,
        haptic_intensity: i32,
        haptics: Option<&HapticEngine>,
    ) {
        if channels == 0 || left.is_empty() {
            return;
        }
        let mut st = match self.dsp.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::Poisoned(p)) => p.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return,
        };

        if self.needs_dsp_reset.swap(false, Ordering::AcqRel) {
            st.zero_state();
        }

        let sample_rate = if sample_rate.is_finite() && sample_rate >= 8000.0 {
            sample_rate
        } else {
            44100.0
        };

        let frame_count = if channels >= 2 && right.is_none() {
            left.len() / channels
        } else if let Some(r) = right {
            left.len().min(r.len())
        } else {
            left.len()
        };
        if frame_count == 0 {
            return;
        }

        let used_frames = frame_count.min(FFT_SIZE);
        let start_offset = frame_count - used_frames;

        // Downmix directly into circular buffer (zero intermediate buffer copy)
        let mut cidx = st.circular_idx;
        if channels >= 2 {
            if let Some(r) = right {
                for i in 0..used_frames {
                    let idx = start_offset + i;
                    let s = (Self::clean_sample(left[idx]) + Self::clean_sample(r[idx])) * 0.5;
                    st.circular_buf[cidx] = s;
                    cidx = (cidx + 1) % FFT_SIZE;
                }
            } else {
                let inv_ch = 1.0 / (channels as f32);
                for i in 0..used_frames {
                    let base = (start_offset + i) * channels;
                    let mut acc = 0.0_f32;
                    for ch in 0..channels {
                        acc += Self::clean_sample(left[base + ch]);
                    }
                    st.circular_buf[cidx] = acc * inv_ch;
                    cidx = (cidx + 1) % FFT_SIZE;
                }
            }
        } else {
            for i in 0..used_frames {
                st.circular_buf[cidx] = Self::clean_sample(left[start_offset + i]);
                cidx = (cidx + 1) % FFT_SIZE;
            }
        }
        st.circular_idx = cidx;

        // Unwrap circular buffer + apply Hann window into FFT input_buf
        let tail = FFT_SIZE - cidx;
        for i in 0..tail {
            st.input_buf[i] = st.circular_buf[cidx + i] * st.hann_window[i];
        }
        for i in 0..cidx {
            let dst = tail + i;
            st.input_buf[dst] = st.circular_buf[i] * st.hann_window[dst];
        }

        let st_ref = &mut *st;
        if st_ref
            .fft
            .process_with_scratch(&mut st_ref.input_buf, &mut st_ref.spectrum_out, &mut st_ref.scratch)
            .is_err()
        {
            return;
        }

        let norm = 1.0_f32 / (FFT_SIZE as f32);
        for j in 0..HALF_LEN {
            let m = st.spectrum_out[j].norm() * norm;
            st.magnitudes[j] = if m.is_finite() { m } else { 0.0 };
        }

        let min_hz: f32 = 60.0;
        // Clamp below Nyquist so 16kHz Bluetooth HFP / 24kHz / 32kHz streams stay alive
        let max_hz: f32 = (sample_rate * 0.45).clamp(2000.0, 16000.0);
        let hz_per_bin = sample_rate / (FFT_SIZE as f32);
        let current_bands = self.band_count.load(Ordering::Acquire).clamp(1, MAX_BANDS);

        let mut frame_max: f32 = 0.000001;
        for i in 0..current_bands {
            let ratio = if current_bands == 1 {
                0.35
            } else {
                (i as f32) / ((current_bands - 1) as f32)
            };
            let center_hz = min_hz * (max_hz / min_hz).powf(ratio);
            let center_bin = (center_hz / hz_per_bin) as usize;
            let span = ((center_bin as f32) * 0.35).max(2.0) as usize;
            let lo = center_bin.saturating_sub(span / 2).clamp(1, HALF_LEN - 1);
            let hi = (lo + span).min(HALF_LEN).max(lo + 1);

            let mut sum = 0.0_f32;
            for j in lo..hi {
                sum += st.magnitudes[j];
            }
            let avg = sum / ((hi - lo).max(1) as f32);
            let boost = if center_hz < 200.0 {
                0.7
            } else if center_hz < 800.0 {
                2.2
            } else if center_hz < 3000.0 {
                3.0
            } else if center_hz < 8000.0 {
                2.0
            } else {
                1.0
            };
            let boosted = avg * boost;
            st.raw_bands[i] = boosted;
            if boosted > frame_max {
                frame_max = boosted;
            }
        }

        // Haptics bass band extraction (20..80Hz deep, 80..150Hz standard)
        if haptic_intensity > 0 {
            if let Some(h) = haptics {
                let deep_min = ((20.0 / hz_per_bin) as usize).clamp(1, HALF_LEN - 2);
                let deep_max = ((80.0 / hz_per_bin) as usize).clamp(deep_min + 1, HALF_LEN - 1);
                let std_min = deep_max;
                let std_max = ((150.0 / hz_per_bin) as usize).clamp(std_min + 1, HALF_LEN);

                let mut deep_sum = 0.0_f32;
                for j in deep_min..deep_max {
                    deep_sum += st.magnitudes[j];
                }
                let deep_avg = deep_sum / ((deep_max - deep_min).max(1) as f32);

                let mut std_sum = 0.0_f32;
                for j in std_min..std_max {
                    std_sum += st.magnitudes[j];
                }
                let std_avg = std_sum / ((std_max - std_min).max(1) as f32);

                h.on_audio_frame(
                    deep_avg,
                    std_avg,
                    haptic_intensity,
                    output_host_time,
                    frame_count,
                    sample_rate,
                );
            }
        }

        // Per-band auto-gain + asymmetric smoothing -> atomic UI publication
        let mut any_live = false;
        for i in 0..current_bands {
            let val = st.raw_bands[i];
            let prev_gain = if st.band_gains[i].is_finite() {
                st.band_gains[i]
            } else {
                0.05
            };
            st.band_gains[i] = if val > prev_gain {
                prev_gain * 0.4 + val * 0.6
            } else {
                prev_gain * 0.98 + val * 0.02
            };
            let ref_gain = st.band_gains[i].max(0.00001);
            let mut scaled = (val / ref_gain).clamp(0.01, 1.0);
            if frame_max < 0.0000002 {
                scaled = 0.01;
            }
            scaled = scaled.sqrt();
            let cur = if st.spectrum_buf[i].is_finite() {
                st.spectrum_buf[i]
            } else {
                0.01
            };
            let next = if scaled > cur {
                cur * 0.3 + scaled * 0.7
            } else {
                cur * 0.5 + scaled * 0.5
            };
            st.spectrum_buf[i] = next;
            if next > 0.02 {
                any_live = true;
            }
            self.published_amps[i].store(next.to_bits(), Ordering::Relaxed);
        }
        self.has_live_audio.store(any_live, Ordering::Release);
    }

    pub fn read_amplitudes(&self, out: &mut [f32]) -> usize {
        let count = self
            .band_count
            .load(Ordering::Acquire)
            .min(out.len())
            .min(MAX_BANDS);
        for i in 0..count {
            out[i] = f32::from_bits(self.published_amps[i].load(Ordering::Relaxed));
        }
        count
    }

    /// Computes asymmetric physics bar heights (2.5pt..17.5pt) with bass-ceiling surge for 60 FPS MenuBarCanvasView.
    pub fn tick_waveform_bars(
        &self,
        delta_time: f64,
        now_unix: f64,
        is_playing: bool,
        is_tap_running: bool,
        bar_count: usize,
        out_heights: &mut [f32],
    ) -> usize {
        let count = bar_count.min(out_heights.len()).min(MAX_BANDS);
        if count == 0 {
            return 0;
        }

        self.update_band_count(count);

        let mut raw_amps = [0.0_f32; MAX_BANDS];
        for i in 0..count {
            let v = f32::from_bits(self.published_amps[i].load(Ordering::Relaxed));
            raw_amps[i] = if v.is_finite() { v } else { 0.0 };
        }
        let has_live = is_tap_running && self.has_live_audio.load(Ordering::Acquire);

        let min_h = 2.5_f32;
        let max_h = 17.5_f32;

        let bass_energy = if has_live && count >= 3 {
            raw_amps[0] * 0.45 + raw_amps[1] * 0.35 + raw_amps[2] * 0.20
        } else {
            0.0
        };
        let bass_surge = if bass_energy > 0.58 {
            let norm = ((bass_energy - 0.58) / 0.28).min(1.0);
            norm.powf(1.20)
        } else {
            0.0
        };

        let dt = if delta_time.is_finite() {
            delta_time.clamp(0.001, 0.25)
        } else {
            0.016
        };
        let attack = (1.0 - (-38.0 * dt).exp()) as f32;
        let decay = (1.0 - (-14.0 * dt).exp()) as f32;
        let time_phase = now_unix * 4.0;

        let mut bars = self.bar_heights.lock().unwrap_or_else(|e| e.into_inner());
        for i in 0..count {
            let energy = if !is_playing {
                0.02_f32
            } else if has_live {
                let band_amp = raw_amps[i].max(0.0).powf(0.85);
                (band_amp.max(bass_surge * 0.98 + band_amp * 0.20)).clamp(0.04, 1.0)
            } else {
                let bar_phase = (i as f64) * 0.55;
                let wave = ((time_phase * 1.2 + bar_phase).sin()
                    * (time_phase * 0.5 + (i as f64) * 0.25).cos()
                    + 1.0)
                    * 0.5;
                ((wave as f32) * 0.40).clamp(0.10, 0.65)
            };

            let target_h = min_h + energy * (max_h - min_h);
            let cur_h = if bars[i].is_finite() { bars[i] } else { min_h };
            let speed = if target_h > cur_h { attack } else { decay };
            let next_h = (cur_h + (target_h - cur_h) * speed).clamp(min_h, max_h);
            bars[i] = next_h;
            out_heights[i] = next_h;
        }
        count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sine_wave_peak_frequency() {
        let engine = AudioDspEngine::new();
        engine.update_band_count(14);
        let sr = 48000.0_f32;
        let freq = 440.0_f32;
        let mut samples = vec![0.0_f32; 4096];
        for (i, s) in samples.iter_mut().enumerate() {
            *s = (2.0 * std::f32::consts::PI * freq * (i as f32) / sr).sin() * 0.8;
        }
        engine.process_pcm(&samples, None, 1, sr, 0, 0, None);
        let mut amps = [0.0_f32; 14];
        let n = engine.read_amplitudes(&mut amps);
        assert_eq!(n, 14);
        assert!(engine.has_live_audio.load(Ordering::Acquire));
        assert!(amps[4] > 0.3 || amps[5] > 0.3 || amps[6] > 0.3);
    }

    #[test]
    fn test_zero_and_interleaved_frames_and_bar_bounds() {
        let engine = AudioDspEngine::new();
        engine.process_pcm(&[], None, 2, 44100.0, 0, 0, None);
        let interleaved = vec![0.25_f32; 2048];
        engine.process_pcm(&interleaved, None, 2, 44100.0, 0, 0, None);

        let mut heights = [0.0_f32; 14];
        let count = engine.tick_waveform_bars(0.016, 100.0, true, true, 14, &mut heights);
        assert_eq!(count, 14);
        for h in heights {
            assert!((2.5..=17.5).contains(&h));
        }
    }

    #[test]
    fn test_multichannel_surround_nan_and_low_sample_rate() {
        let engine = AudioDspEngine::new();
        engine.update_band_count(14);
        // 6-channel 5.1 interleaved with NaN/Inf injected — must never panic or poison
        let mut surround = vec![0.3_f32; 6 * 1024];
        surround[12] = f32::NAN;
        surround[13] = f32::INFINITY;
        engine.process_pcm(&surround, None, 6, 16000.0, 0, 0, None);

        let mut heights = [0.0_f32; 14];
        let n = engine.tick_waveform_bars(0.016, 100.0, true, true, 14, &mut heights);
        assert_eq!(n, 14);
        for h in heights {
            assert!(h.is_finite() && (2.5..=17.5).contains(&h));
        }
    }
}
