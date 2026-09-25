//! Portable core for **thecloser** — the Windows interview-copilot overlay.
//!
//! Everything here is OS- and GUI-independent so it compiles and unit-tests on
//! any host (including the macOS box this was authored on). The Windows-only
//! pieces — the capture-excluded overlay window, WASAPI audio capture, and
//! global hotkeys — live in the `thecloser` binary crate, which depends on
//! this library.
//!
//! Ported faithfully from the macOS app (`MacOverlay/`):
//! * [`models`]   ← `OverlayViewModel.availableModels` + `AIManager` routing
//! * [`modes`]    ← `SessionMode.swift`
//! * [`filter`]   ← `TranscriptFilter.swift`
//! * [`ai`]       ← `AIManager.swift` (streaming + non-streaming)
//! * [`prompt`]   ← `AIController.resolveActivePrompt`
//! * [`settings`] ← `UserDefaults`-backed config, here a JSON file
//! * [`files`]    ← `ResumeImporter.swift` (PDF/DOCX/RTF/TXT/MD extraction)
//! * [`prompts`]  ← `PromptStore.swift` + `PromptPreset.swift`
//! * [`resumes`]  ← `ResumeStore` / `ResumePreset` / `ResumeGeneration` / `ResumeScore`
//! * [`store`]    ← `JSONStore.swift`

pub mod ai;
pub mod files;
pub mod filter;
pub mod models;
pub mod modes;
pub mod prompt;
pub mod prompts;
pub mod resumes;
pub mod settings;
pub mod store;
pub mod vad;

pub use ai::{AiError, AiRequest, ProviderKeys, StreamEvent};
pub use files::{ImportError, Imported};
pub use filter::TranscriptFilter;
pub use models::{available_models, route, Api, ModelInfo, Route};
pub use modes::{QuickAction, SessionMode};
pub use prompt::Attachment;
pub use prompts::{PromptKind, PromptPreset, PromptStore};
pub use resumes::{ResumeGeneration, ResumePreset, ResumeScore, ResumeStore, ScoreBand};
pub use settings::{AudioSource, Settings, SttProvider};
pub use vad::{Segmenter, VadConfig};
