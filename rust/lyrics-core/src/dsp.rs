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
    downmix_buf: Vec<f32>,
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

        // Standard normalized Hann window
        let mut hann_window = vec![0.0_f32; FFT_SIZE];
        let denom = (FFT_SIZE - 1) as f32;
        for (i, w) in hann_window.iter_mut().enumerate() {
            *w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (i as f32) / denom).cos());
        }

        Self {
            circular_buf: vec![0.0; FFT_SIZE],
            circular_idx: 0,
            downmix_buf: vec![0.0; FFT_SIZE],
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
}

pub struct AudioDspEngine {
    dsp: Mutex<DspState>,
    pub band_count: AtomicUsize,
    pub has_live_audio: AtomicBool,
    published_amps: [AtomicU32; MAX_BANDS],
    // UI-thread-only ballistic bar heights (2.5..17.5 pt)
    bar_heights: Mutex<Vec<f32>>,
}

impl AudioDspEngine {
    pub fn new() -> Self {
        let published_amps = std::array::from_fn(|_| AtomicU32::new(0.05_f32.to_bits()));
        Self {
            dsp: Mutex::new(DspState::new()),
            band_count: AtomicUsize::new(14),
            has_live_audio: AtomicBool::new(false),
            published_amps,
            bar_heights: Mutex::new(vec![2.5; 14]),
        }
    }

    pub fn update_band_count(&self, count: usize) {
        let clamped = count.clamp(1, MAX_BANDS);
        let prev = self.band_count.swap(clamped, Ordering::AcqRel);
        if prev == clamped {
            return;
        }
        if let Ok(mut st) = self.dsp.try_lock() {
            for i in 0..clamped {
                st.spectrum_buf[i] = 0.0;
                st.band_gains[i] = 0.05;
                self.published_amps[i].store(0.01_f32.to_bits(), Ordering::Relaxed);
            }
        }
        if let Ok(mut bars) = self.bar_heights.lock() {
            *bars = vec![2.5; clamped];
        }
    }

    pub fn reset(&self) {
        self.has_live_audio.store(false, Ordering::Release);
        for slot in &self.published_amps {
            slot.store(0.0_f32.to_bits(), Ordering::Relaxed);
        }
        if let Ok(mut bars) = self.bar_heights.lock() {
            for h in bars.iter_mut() {
                *h = 2.5;
            }
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
        let Ok(mut st) = self.dsp.try_lock() else {
            return;
        };

        let sample_rate = if sample_rate > 8000.0 {
            sample_rate
        } else {
            44100.0
        };

        let frame_count = if channels == 2 && right.is_none() {
            left.len() / 2
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

        if channels >= 2 {
            if let Some(r) = right {
                for i in 0..used_frames {
                    let idx = start_offset + i;
                    st.downmix_buf[i] = (left[idx] + r[idx]) * 0.5;
                }
            } else {
                for i in 0..used_frames {
                    let base = (start_offset + i) * 2;
                    st.downmix_buf[i] = (left[base] + left[base + 1]) * 0.5;
                }
            }
        } else {
            st.downmix_buf[..used_frames]
                .copy_from_slice(&left[start_offset..start_offset + used_frames]);
        }

        // Write into circular buffer
        let mut cidx = st.circular_idx;
        for i in 0..used_frames {
            let sample = st.downmix_buf[i];
            st.circular_buf[cidx] = sample;
            cidx = (cidx + 1) % FFT_SIZE;
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

        // Forward real-to-complex FFT
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
            st.magnitudes[j] = st.spectrum_out[j].norm() * norm;
        }

        let min_hz: f32 = 60.0;
        let max_hz: f32 = 16000.0;
        let hz_per_bin = sample_rate / (FFT_SIZE as f32);
        let current_bands = self.band_count.load(Ordering::Acquire).clamp(1, MAX_BANDS);

        let mut frame_max: f32 = 0.000001;
        for i in 0..current_bands {
            let ratio = (i as f32) / ((current_bands.saturating_sub(1)).max(1) as f32);
            let center_hz = min_hz * (max_hz / min_hz).powf(ratio);
            let center_bin = (center_hz / hz_per_bin) as usize;
            let span = ((center_bin as f32) * 0.15).max(1.0) as usize;
            let lo = center_bin.saturating_sub(span / 2).max(1);
            let hi = (lo + span).min(HALF_LEN - 1);

            let mut sum = 0.0_f32;
            if hi > lo {
                for j in lo..hi {
                    sum += st.magnitudes[j];
                }
            }
            let avg = sum / ((hi.saturating_sub(lo)).max(1) as f32);
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
                let deep_min = ((20.0 / hz_per_bin) as usize).max(1);
                let deep_max = ((80.0 / hz_per_bin) as usize).min(HALF_LEN - 1);
                let std_min = deep_max;
                let std_max = ((150.0 / hz_per_bin) as usize).min(HALF_LEN - 1);

                let mut deep_sum = 0.0_f32;
                if deep_max > deep_min {
                    for j in deep_min..deep_max {
                        deep_sum += st.magnitudes[j];
                    }
                }
                let deep_avg = deep_sum / ((deep_max.saturating_sub(deep_min)).max(1) as f32);

                let mut std_sum = 0.0_f32;
                if std_max > std_min {
                    for j in std_min..std_max {
                        std_sum += st.magnitudes[j];
                    }
                }
                let std_avg = std_sum / ((std_max.saturating_sub(std_min)).max(1) as f32);

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
            st.band_gains[i] = if val > st.band_gains[i] {
                st.band_gains[i] * 0.4 + val * 0.6
            } else {
                st.band_gains[i] * 0.98 + val * 0.02
            };
            let ref_gain = st.band_gains[i].max(0.00001);
            let mut scaled = (val / ref_gain).clamp(0.01, 1.0);
            if frame_max < 0.0000002 {
                scaled = 0.01;
            }
            scaled = scaled.sqrt();
            let cur = st.spectrum_buf[i];
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
            raw_amps[i] = f32::from_bits(self.published_amps[i].load(Ordering::Relaxed));
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

        let dt = delta_time.clamp(0.001, 0.25) as f32;
        let attack_alpha = 1.0 - (-38.0 * dt).exp();
        let decay_alpha = 1.0 - (-14.0 * dt).exp();
        let time_phase = now_unix * 4.0;

        if let Ok(mut bars) = self.bar_heights.lock() {
            if bars.len() != count {
                *bars = vec![min_h; count];
            }
            for i in 0..count {
                let energy = if !is_playing {
                    0.02
                } else if has_live {
                    let band_amp = raw_amps[i].powf(0.85);
                    let combined = band_amp.max(bass_surge * 0.98 + band_amp * 0.20);
                    combined.clamp(0.04, 1.0)
                } else {
                    let bar_phase = (i as f64) * 0.55;
                    let wave = ((time_phase * 1.2 + bar_phase).sin()
                        * (time_phase * 0.5 + (i as f64) * 0.25).cos()
                        + 1.0)
                        * 0.5;
                    ((wave as f32) * 0.40).clamp(0.10, 0.65)
                };

                let target_h = min_h + energy * (max_h - min_h);
                let cur_h = bars[i];
                let speed = if target_h > cur_h {
                    attack_alpha
                } else {
                    decay_alpha
                };
                let new_h = cur_h + (target_h - cur_h) * speed;
                bars[i] = new_h;
                out_heights[i] = new_h;
            }
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
        // Generate 4096 samples at 1212Hz (band 7 center frequency)
        let mut mono = vec![0.0_f32; FFT_SIZE];
        for (i, s) in mono.iter_mut().enumerate() {
            *s = (2.0 * std::f32::consts::PI * 1212.0 * (i as f32) / sr).sin() * 0.6;
        }
        engine.process_pcm(&mono, None, 1, sr, 0, 0, None);
        let mut out = [0.0_f32; 14];
        let n = engine.read_amplitudes(&mut out);
        assert_eq!(n, 14);
        // 1212Hz lands directly in band 7, which must exceed band 0 (60Hz)
        let mid_max = out[6..=8].iter().cloned().fold(0.0_f32, f32::max);
        assert!(mid_max > out[0], "Expected ~1.2kHz band ({mid_max}) > 60Hz band ({})", out[0]);
    }

    #[test]
    fn test_zero_and_interleaved_frames_and_bar_bounds() {
        let engine = AudioDspEngine::new();
        // Empty input must not panic
        engine.process_pcm(&[], None, 2, 44100.0, 0, 0, None);

        // Interleaved stereo odd length
        let interleaved = vec![0.2_f32; 513];
        engine.process_pcm(&interleaved, None, 2, 44100.0, 0, 0, None);

        let mut heights = [0.0_f32; 24];
        let n = engine.tick_waveform_bars(0.016, 1234.5, true, false, 24, &mut heights);
        assert_eq!(n, 24);
        for h in &heights[..n] {
            assert!(*h >= 2.5 && *h <= 17.5, "height out of bounds: {h}");
        }
    }
}
