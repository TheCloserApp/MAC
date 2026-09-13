//! The async backend: a Tokio runtime plus the channels that connect it to the
//! egui UI thread.
//!
//! The UI never blocks. It hands work to the backend (start recording, stream
//! an answer) and drains [`UiEvent`]s each frame. Background tasks push events
//! and call `request_repaint` so the UI wakes to render them.

use std::collections::HashMap;
use std::sync::mpsc::Sender;

use copilot_core::ai::{self, AiRequest, StreamEvent};
use copilot_core::filter::TranscriptFilter;
use copilot_core::settings::{AudioSource, SttProvider};

use crate::audio::{AudioCapture, Utterance};
use crate::transcribe;

/// Messages from background work to the UI.
pub enum UiEvent {
    /// A recognised, meaningful utterance to append to the live transcript.
    Transcript(String),
    /// A human-readable status / error line.
    Status(String),
    /// A streamed token for the assistant turn `turn`.
    AiChunk { turn: u64, text: String },
    /// Token usage for `turn` (shown as a subtle cost line).
    AiUsage { turn: u64, input: u32, output: u32 },
    /// The stream for `turn` finished cleanly.
    AiDone { turn: u64 },
    /// The stream for `turn` failed.
    AiError { turn: u64, message: String },
}

pub struct Backend {
    rt: tokio::runtime::Runtime,
    http: reqwest::Client,
    ui_tx: Sender<UiEvent>,
    ctx: egui::Context,
    capture: Option<AudioCapture>,
    ai_tasks: HashMap<u64, tokio::task::JoinHandle<()>>,
}

impl Backend {
    pub fn new(ctx: egui::Context, ui_tx: Sender<UiEvent>) -> Self {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("failed to start Tokio runtime");
        Backend { rt, http: ai::streaming_client(), ui_tx, ctx, capture: None, ai_tasks: HashMap::new() }
    }

    pub fn is_recording(&self) -> bool {
        self.capture.is_some()
    }

    /// Begin capturing audio and transcribing utterances. STT settings are
    /// snapshotted now; change them and restart to apply.
    pub fn start_recording(
        &mut self,
        source: AudioSource,
        stt_provider: SttProvider,
        stt_key: String,
        stt_model: String,
    ) {
        if self.capture.is_some() {
            return;
        }
        // Audio thread → transcription worker.
        let (utt_tx, mut utt_rx) = tokio::sync::mpsc::channel::<Utterance>(16);
        // Audio thread → UI (status), forwarded into the UiEvent channel.
        let (status_tx, status_rx) = std::sync::mpsc::channel::<String>();
        self.spawn_status_forwarder(status_rx);

        self.capture = Some(AudioCapture::start(source, utt_tx, status_tx));

        // Transcription worker: transcribe each utterance, keep the meaningful
        // ones, drop noise/filler exactly like the macOS auto-send gate.
        let http = self.http.clone();
        let ui_tx = self.ui_tx.clone();
        let ctx = self.ctx.clone();
        self.rt.spawn(async move {
            while let Some(utt) = utt_rx.recv().await {
                match transcribe::transcribe(
                    &http,
                    stt_provider,
                    &stt_key,
                    &stt_model,
                    &utt.samples,
                    utt.sample_rate,
                )
                .await
                {
                    Ok(text) if TranscriptFilter::is_meaningful(&text) => {
                        let _ = ui_tx.send(UiEvent::Transcript(text));
                        ctx.request_repaint();
                    }
                    Ok(_) => {} // recognised but noise/filler — ignore
                    Err(e) => {
                        let _ = ui_tx.send(UiEvent::Status(e));
                        ctx.request_repaint();
                    }
                }
            }
        });
    }

    pub fn stop_recording(&mut self) {
        // Dropping the capture stops the WASAPI stream and closes the utterance
        // channel, which ends the transcription worker.
        self.capture = None;
    }

    /// Stream an assistant answer for `turn`. A previous stream for the same
    /// turn (Retry) is cancelled first.
    pub fn stream_ai(&mut self, turn: u64, req: AiRequest) {
        self.cancel_ai(turn);
        let http = self.http.clone();
        let ui_tx = self.ui_tx.clone();
        let ctx = self.ctx.clone();
        let handle = self.rt.spawn(async move {
            let send = |ev: UiEvent| {
                let _ = ui_tx.send(ev);
                ctx.request_repaint();
            };
            let result = ai::stream_message(&http, &req, |event| match event {
                StreamEvent::Chunk(text) => send(UiEvent::AiChunk { turn, text }),
                StreamEvent::Usage { input_tokens, output_tokens } => {
                    send(UiEvent::AiUsage { turn, input: input_tokens, output: output_tokens })
                }
            })
            .await;
            match result {
                Ok(()) => send(UiEvent::AiDone { turn }),
                Err(e) => send(UiEvent::AiError { turn, message: e.to_string() }),
            }
        });
        self.ai_tasks.insert(turn, handle);
    }

    /// Mark a turn's stream as finished (called when the UI sees Done/Error).
    pub fn finish_ai(&mut self, turn: u64) {
        self.ai_tasks.remove(&turn);
    }

    pub fn cancel_ai(&mut self, turn: u64) {
        if let Some(h) = self.ai_tasks.remove(&turn) {
            h.abort();
        }
    }

    pub fn cancel_all_ai(&mut self) {
        for (_, h) in self.ai_tasks.drain() {
            h.abort();
        }
    }

    /// Forward audio-thread status strings into the UI event channel.
    fn spawn_status_forwarder(&self, status_rx: std::sync::mpsc::Receiver<String>) {
        let ui_tx = self.ui_tx.clone();
        let ctx = self.ctx.clone();
        std::thread::spawn(move || {
            while let Ok(msg) = status_rx.recv() {
                let _ = ui_tx.send(UiEvent::Status(msg));
                ctx.request_repaint();
            }
        });
    }
}
