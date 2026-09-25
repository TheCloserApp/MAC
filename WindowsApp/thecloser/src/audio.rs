//! Live audio capture → VAD → utterances.
//!
//! On Windows this uses WASAPI (via the `wasapi` crate) to capture either the
//! microphone or — the important one for an interview copilot — a **loopback**
//! of the default render device, i.e. whatever the interviewer is saying
//! through your speakers/headset. WASAPI auto-converts to 16 kHz mono 16-bit,
//! which the [`Segmenter`] slices into utterances and hands to the caller.
//!
//! Off Windows the capture is a no-op so the rest of the app still builds.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use copilot_core::settings::AudioSource;

/// One completed utterance: 16-bit mono PCM plus its sample rate.
pub struct Utterance {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
}

/// A running capture session. Dropping it (or calling [`stop`](AudioCapture::stop))
/// tears down the WASAPI stream.
pub struct AudioCapture {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl AudioCapture {
    /// Start capturing `source`, sending each completed utterance on `tx`.
    /// Errors are reported on `status` rather than panicking the audio thread.
    pub fn start(
        source: AudioSource,
        tx: tokio::sync::mpsc::Sender<Utterance>,
        status: std::sync::mpsc::Sender<String>,
    ) -> AudioCapture {
        let stop = Arc::new(AtomicBool::new(false));
        let handle = spawn_capture(source, tx, status, stop.clone());
        AudioCapture { stop, handle }
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for AudioCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

// ── Windows: real WASAPI capture ─────────────────────────────────────────────

#[cfg(windows)]
fn spawn_capture(
    source: AudioSource,
    tx: tokio::sync::mpsc::Sender<Utterance>,
    status: std::sync::mpsc::Sender<String>,
    stop: Arc<AtomicBool>,
) -> Option<JoinHandle<()>> {
    let handle = std::thread::Builder::new()
        .name("thecloser-audio".into())
        .spawn(move || {
            if let Err(e) = capture_loop(source, &tx, &stop) {
                let _ = status.send(format!("Audio capture stopped: {e}"));
            }
        })
        .ok();
    handle
}

#[cfg(windows)]
fn capture_loop(
    source: AudioSource,
    tx: &tokio::sync::mpsc::Sender<Utterance>,
    stop: &Arc<AtomicBool>,
) -> Result<(), String> {
    use std::collections::VecDeque;
    use copilot_core::vad::{Segmenter, VadConfig};
    use wasapi::{
        get_default_device, initialize_mta, Direction, SampleType, ShareMode, WaveFormat,
    };

    const SR: u32 = 16_000;

    // COM init for this thread (MTA). Harmless if already initialised.
    let _ = initialize_mta();

    // Loopback = capture FROM the render device; mic = the capture device.
    let direction = match source {
        AudioSource::System => Direction::Render,
        AudioSource::Microphone => Direction::Capture,
    };
    let device = get_default_device(&direction).map_err(|e| e.to_string())?;
    let mut audio_client = device.get_iaudioclient().map_err(|e| e.to_string())?;

    // Ask WASAPI for 16 kHz mono 16-bit and let it convert (`convert = true`).
    let desired = WaveFormat::new(16, 16, &SampleType::Int, SR as usize, 1, None);
    let (_def_period, min_period) = audio_client.get_periods().map_err(|e| e.to_string())?;
    audio_client
        .initialize_client(&desired, min_period, &Direction::Capture, &ShareMode::Shared, true)
        .map_err(|e| e.to_string())?;

    let h_event = audio_client.set_get_eventhandle().map_err(|e| e.to_string())?;
    let capture_client = audio_client.get_audiocaptureclient().map_err(|e| e.to_string())?;
    audio_client.start_stream().map_err(|e| e.to_string())?;

    let mut seg = Segmenter::new(VadConfig { sample_rate: SR, ..Default::default() });
    let mut bytes: VecDeque<u8> = VecDeque::new();

    while !stop.load(Ordering::SeqCst) {
        capture_client
            .read_from_device_to_deque(&mut bytes)
            .map_err(|e| e.to_string())?;

        // Drain complete 16-bit samples (mono → 2 bytes each).
        if bytes.len() >= 2 {
            let mut block: Vec<i16> = Vec::with_capacity(bytes.len() / 2);
            while bytes.len() >= 2 {
                let lo = bytes.pop_front().unwrap();
                let hi = bytes.pop_front().unwrap();
                block.push(i16::from_le_bytes([lo, hi]));
            }
            for utt in seg.push(&block) {
                if tx.blocking_send(Utterance { samples: utt, sample_rate: SR }).is_err() {
                    return Ok(()); // receiver gone → recording stopped
                }
            }
        }

        // Wait for the next buffer, but wake periodically to check `stop` and to
        // keep polling during silent loopback stretches (a timeout isn't fatal).
        let _ = h_event.wait_for_event(200);
    }

    if let Some(utt) = seg.flush() {
        let _ = tx.blocking_send(Utterance { samples: utt, sample_rate: SR });
    }
    let _ = audio_client.stop_stream();
    Ok(())
}

// ── Non-Windows: no capture (keeps the app buildable everywhere) ─────────────

#[cfg(not(windows))]
fn spawn_capture(
    _source: AudioSource,
    _tx: tokio::sync::mpsc::Sender<Utterance>,
    status: std::sync::mpsc::Sender<String>,
    _stop: Arc<AtomicBool>,
) -> Option<JoinHandle<()>> {
    let _ = status.send("Audio capture is only implemented on Windows.".to_string());
    None
}
