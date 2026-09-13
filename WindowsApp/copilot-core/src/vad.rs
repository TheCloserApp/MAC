//! Energy-based voice-activity segmenter.
//!
//! Audio arrives from WASAPI as a stream of 16-bit mono samples. This splits
//! it into *utterances*: a run of speech bracketed by silence. Each completed
//! utterance is what gets sent to the STT backend, so the copilot transcribes
//! and answers a question as soon as the speaker pauses — the Windows analogue
//! of the macOS VAD / silence auto-send flow.
//!
//! Pure logic (no audio APIs), so it unit-tests on any host.

use std::collections::VecDeque;

/// Tunable thresholds for [`Segmenter`].
#[derive(Debug, Clone, Copy)]
pub struct VadConfig {
    pub sample_rate: u32,
    /// RMS amplitude (on the i16 scale, 0..32767) above which a window counts
    /// as speech.
    pub speech_rms: f32,
    /// Analysis window length in milliseconds.
    pub window_ms: u32,
    /// Trailing silence that ends an utterance.
    pub hang_ms: u32,
    /// Minimum speech before an utterance is worth emitting.
    pub min_speech_ms: u32,
    /// Pre-roll kept before speech onset so the first word isn't clipped.
    pub preroll_ms: u32,
    /// Hard cap so a long monologue is flushed instead of buffering forever.
    pub max_utterance_ms: u32,
}

impl Default for VadConfig {
    fn default() -> Self {
        VadConfig {
            sample_rate: 16_000,
            speech_rms: 500.0,
            window_ms: 20,
            hang_ms: 700,
            min_speech_ms: 200,
            preroll_ms: 240,
            max_utterance_ms: 15_000,
        }
    }
}

/// Streaming segmenter. Feed samples with [`push`](Segmenter::push); it returns
/// any utterances that completed. Call [`flush`](Segmenter::flush) when capture
/// stops to emit a trailing in-progress utterance.
pub struct Segmenter {
    cfg: VadConfig,
    window: usize,
    hang_windows: u32,
    min_speech_windows: u32,
    preroll_cap: usize,
    max_samples: usize,

    acc: Vec<i16>,
    current: Vec<i16>,
    preroll: VecDeque<i16>,
    in_speech: bool,
    silence_run: u32,
    speech_run: u32,
}

impl Segmenter {
    pub fn new(cfg: VadConfig) -> Self {
        let window = ((cfg.sample_rate * cfg.window_ms) / 1000).max(1) as usize;
        let per_window = |ms: u32| (ms / cfg.window_ms).max(1);
        Segmenter {
            window,
            hang_windows: per_window(cfg.hang_ms),
            min_speech_windows: per_window(cfg.min_speech_ms),
            preroll_cap: (cfg.sample_rate as usize * cfg.preroll_ms as usize) / 1000,
            max_samples: (cfg.sample_rate as usize * cfg.max_utterance_ms as usize) / 1000,
            acc: Vec::with_capacity(window * 2),
            current: Vec::new(),
            preroll: VecDeque::new(),
            in_speech: false,
            silence_run: 0,
            speech_run: 0,
            cfg,
        }
    }

    /// Feed a block of samples; returns every utterance that completed within
    /// this block (usually zero or one).
    pub fn push(&mut self, samples: &[i16]) -> Vec<Vec<i16>> {
        let mut out = Vec::new();
        self.acc.extend_from_slice(samples);
        while self.acc.len() >= self.window {
            let win: Vec<i16> = self.acc.drain(..self.window).collect();
            if let Some(utt) = self.process_window(&win) {
                out.push(utt);
            }
        }
        out
    }

    /// Emit any in-progress utterance (call once when capture stops).
    pub fn flush(&mut self) -> Option<Vec<i16>> {
        if self.in_speech && self.speech_run >= self.min_speech_windows {
            let utt = std::mem::take(&mut self.current);
            self.reset();
            return Some(utt);
        }
        self.reset();
        None
    }

    fn reset(&mut self) {
        self.current.clear();
        self.in_speech = false;
        self.silence_run = 0;
        self.speech_run = 0;
    }

    fn process_window(&mut self, win: &[i16]) -> Option<Vec<i16>> {
        let is_speech = rms(win) >= self.cfg.speech_rms;
        if is_speech {
            if !self.in_speech {
                // Onset: prepend the pre-roll so the first phoneme survives.
                self.in_speech = true;
                self.current.clear();
                self.current.extend(self.preroll.iter().copied());
            }
            self.current.extend_from_slice(win);
            self.speech_run += 1;
            self.silence_run = 0;
        } else if self.in_speech {
            // Trailing silence inside an utterance.
            self.current.extend_from_slice(win);
            self.silence_run += 1;
            if self.silence_run >= self.hang_windows {
                let emit = self.speech_run >= self.min_speech_windows;
                let utt = std::mem::take(&mut self.current);
                self.reset();
                if emit {
                    return Some(utt);
                }
            }
        } else {
            // Idle silence: keep a rolling pre-roll ring.
            for &s in win {
                if self.preroll.len() >= self.preroll_cap {
                    self.preroll.pop_front();
                }
                self.preroll.push_back(s);
            }
        }
        // Hard cap: flush a monologue that never pauses.
        if self.in_speech && self.current.len() >= self.max_samples {
            let utt = std::mem::take(&mut self.current);
            self.reset();
            return Some(utt);
        }
        None
    }
}

fn rms(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
    (sum_sq / samples.len() as f64).sqrt() as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(n: usize, amp: i16) -> Vec<i16> {
        // Alternating ±amp → constant RMS ≈ amp, regardless of pitch.
        (0..n).map(|i| if i % 2 == 0 { amp } else { -amp }).collect()
    }

    #[test]
    fn pure_silence_emits_nothing() {
        let mut seg = Segmenter::new(VadConfig::default());
        let out = seg.push(&vec![0i16; 16_000]); // 1s of silence
        assert!(out.is_empty());
        assert!(seg.flush().is_none());
    }

    #[test]
    fn speech_then_silence_emits_one_utterance() {
        let cfg = VadConfig::default();
        let mut seg = Segmenter::new(cfg);
        // 500ms of speech …
        let mut out = seg.push(&tone(8_000, 8_000));
        assert!(out.is_empty(), "should not emit while still speaking");
        // … then 800ms of silence (> hang_ms) closes the utterance.
        out.extend(seg.push(&vec![0i16; 12_800]));
        assert_eq!(out.len(), 1, "exactly one utterance after the pause");
        // It should contain roughly the speech plus pre-roll, and be substantial.
        assert!(out[0].len() >= 8_000, "utterance too short: {}", out[0].len());
    }

    #[test]
    fn quiet_blip_is_dropped() {
        let cfg = VadConfig::default();
        let mut seg = Segmenter::new(cfg);
        // 40ms of speech is below min_speech_ms (200ms) → discarded.
        let mut out = seg.push(&tone(640, 8_000));
        out.extend(seg.push(&vec![0i16; 12_800]));
        assert!(out.is_empty(), "a tiny blip must not produce an utterance");
    }

    #[test]
    fn long_monologue_is_flushed_at_cap() {
        let cfg = VadConfig::default();
        let max = cfg.max_utterance_ms; // 15s
        let mut seg = Segmenter::new(cfg);
        // 20s of continuous speech, fed in 1s blocks, must flush at least once.
        let mut total = 0;
        for _ in 0..20 {
            total += seg.push(&tone(16_000, 8_000)).len();
        }
        assert!(total >= 1, "a monologue longer than {max}ms must be flushed");
    }
}
