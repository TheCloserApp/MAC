//! Cloud speech-to-text for one utterance.
//!
//! An utterance (16-bit mono PCM from the VAD) is WAV-encoded in memory and
//! POSTed to the user's chosen STT backend. Mirrors the macOS app's cloud
//! transcription path (ElevenLabs Scribe), with OpenAI Whisper as the default
//! (it reuses the OpenAI key most users already have).

use std::io::Cursor;

use copilot_core::settings::SttProvider;
use serde_json::Value;

const OPENAI_STT_URL: &str = "https://api.openai.com/v1/audio/transcriptions";
const ELEVENLABS_STT_URL: &str = "https://api.elevenlabs.io/v1/speech-to-text";

/// Transcribe one utterance. Returns the recognised text (possibly empty).
pub async fn transcribe(
    http: &reqwest::Client,
    provider: SttProvider,
    api_key: &str,
    openai_model: &str,
    samples: &[i16],
    sample_rate: u32,
) -> Result<String, String> {
    if api_key.trim().is_empty() {
        return Err(format!("no API key set for {}", provider.label()));
    }
    let wav = encode_wav(samples, sample_rate).map_err(|e| format!("WAV encode failed: {e}"))?;

    let file_part = reqwest::multipart::Part::bytes(wav)
        .file_name("audio.wav")
        .mime_str("audio/wav")
        .map_err(|e| e.to_string())?;

    let (req, _) = match provider {
        SttProvider::OpenAi => {
            let form = reqwest::multipart::Form::new()
                .text("model", openai_model.to_string())
                .text("response_format", "json")
                .part("file", file_part);
            (
                http.post(OPENAI_STT_URL)
                    .header("authorization", format!("Bearer {api_key}"))
                    .multipart(form),
                (),
            )
        }
        SttProvider::ElevenLabs => {
            let form = reqwest::multipart::Form::new()
                .text("model_id", "scribe_v1")
                .part("file", file_part);
            (
                http.post(ELEVENLABS_STT_URL)
                    .header("xi-api-key", api_key)
                    .multipart(form),
                (),
            )
        }
    };

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(format!("STT error {status}: {}", &body[..body.len().min(300)]));
    }
    let json: Value = serde_json::from_str(&body).map_err(|e| format!("bad STT response: {e}"))?;
    let text = json["text"].as_str().unwrap_or("").trim().to_string();
    Ok(text)
}

/// Encode mono 16-bit PCM as a WAV byte buffer.
fn encode_wav(samples: &[i16], sample_rate: u32) -> Result<Vec<u8>, hound::Error> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut cursor = Cursor::new(Vec::<u8>::new());
    {
        let mut writer = hound::WavWriter::new(&mut cursor, spec)?;
        for &s in samples {
            writer.write_sample(s)?;
        }
        writer.finalize()?;
    }
    Ok(cursor.into_inner())
}
