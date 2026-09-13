//! Multi-provider AI client: streaming + non-streaming, over `reqwest`.
//!
//! Port of `AIManager.swift`. One [`stream_message`] call routes a model id to
//! Anthropic or any OpenAI-compatible provider (OpenAI/Kimi/Grok/DeepSeek/
//! NVIDIA/OpenRouter) and emits [`StreamEvent`]s as tokens arrive.

use futures_util::StreamExt;
use serde_json::{json, Value};

use crate::models::{route, Api, Route};

/// The seven AI provider keys, one per routing branch.
#[derive(Debug, Clone, Default)]
pub struct ProviderKeys {
    pub anthropic: String,
    pub openai: String,
    pub moonshot: String,
    pub grok: String,
    pub deepseek: String,
    pub nvidia: String,
    pub openrouter: String,
}

/// Emitted as a streaming response is received.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamEvent {
    /// A chunk of text to append to the assistant response.
    Chunk(String),
    /// Final token counts, emitted once before the stream finishes.
    Usage { input_tokens: u32, output_tokens: u32 },
}

/// Everything needed to issue one request.
#[derive(Debug, Clone)]
pub struct AiRequest {
    pub text: String,
    pub model: String,
    pub system_prompt: String,
    /// `(user, assistant)` turns, oldest first.
    pub history: Vec<(String, String)>,
    pub keys: ProviderKeys,
    pub max_tokens: u32,
    /// Optional PNG screenshot/clipboard image, base64-encoded (no data: prefix).
    pub image_base64: Option<String>,
}

impl AiRequest {
    pub fn new(text: impl Into<String>, model: impl Into<String>, keys: ProviderKeys) -> Self {
        AiRequest {
            text: text.into(),
            model: model.into(),
            system_prompt: "You are a helpful assistant. Respond helpfully and concisely.".into(),
            history: Vec::new(),
            keys,
            max_tokens: 2048,
            image_base64: None,
        }
    }
    pub fn system(mut self, prompt: impl Into<String>) -> Self {
        self.system_prompt = prompt.into();
        self
    }
    pub fn history(mut self, history: Vec<(String, String)>) -> Self {
        self.history = history;
        self
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("invalid API URL")]
    InvalidUrl,
    #[error("network error: {0}")]
    Network(String),
    #[error("API error {0}: {1}")]
    Api(u16, String),
    #[error("failed to parse API response: {0}")]
    Parse(String),
    #[error("no API key set for {0}")]
    MissingKey(&'static str),
}

impl From<reqwest::Error> for AiError {
    fn from(e: reqwest::Error) -> Self {
        AiError::Network(e.to_string())
    }
}

/// Build a client tuned for streaming (no overall timeout — the caller cancels
/// by dropping the future; a connect timeout still guards a dead network).
pub fn streaming_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap_or_default()
}

/// Stream a response, invoking `on_event` for every chunk and the final usage.
/// Cancellation: drop the returned future to abort the request.
pub async fn stream_message<F>(
    client: &reqwest::Client,
    req: &AiRequest,
    mut on_event: F,
) -> Result<(), AiError>
where
    F: FnMut(StreamEvent),
{
    let route = route(&req.model, &req.keys);
    if route.api_key.trim().is_empty() {
        return Err(AiError::MissingKey(route.provider_name));
    }
    match route.api {
        Api::Anthropic => stream_anthropic(client, req, &route, &mut on_event).await,
        Api::OpenAiCompatible => stream_openai(client, req, &route, &mut on_event).await,
    }
}

/// Non-streaming request returning the whole response (title regeneration,
/// one-shot helpers). Mirrors `AIManager.sendMessage`.
pub async fn send_message(client: &reqwest::Client, req: &AiRequest) -> Result<String, AiError> {
    let route = route(&req.model, &req.keys);
    if route.api_key.trim().is_empty() {
        return Err(AiError::MissingKey(route.provider_name));
    }
    let (url, headers, body) = match route.api {
        Api::Anthropic => anthropic_payload(req, &route, false),
        Api::OpenAiCompatible => openai_payload(req, &route, false),
    };
    let resp = send(client, &url, headers, &body, true).await?;
    let status = resp.status().as_u16();
    let text = resp.text().await?;
    if status != 200 {
        return Err(AiError::Api(status, text));
    }
    let json: Value = serde_json::from_str(&text).map_err(|e| AiError::Parse(e.to_string()))?;
    let out = match route.api {
        Api::Anthropic => json["content"][0]["text"].as_str().map(str::to_string),
        Api::OpenAiCompatible => json["choices"][0]["message"]["content"]
            .as_str()
            .map(str::to_string),
    };
    out.ok_or_else(|| AiError::Parse(format!("unexpected response shape: {}", &text[..text.len().min(400)])))
}

// ── Payload builders ─────────────────────────────────────────────────────────

type Headers = Vec<(&'static str, String)>;

fn anthropic_payload(req: &AiRequest, route: &Route, stream: bool) -> (String, Headers, Value) {
    let mut messages: Vec<Value> = Vec::new();
    for (user, assistant) in &req.history {
        messages.push(json!({ "role": "user", "content": user }));
        messages.push(json!({ "role": "assistant", "content": assistant }));
    }
    let mut parts: Vec<Value> = Vec::new();
    if let Some(b64) = &req.image_base64 {
        parts.push(json!({
            "type": "image",
            "source": { "type": "base64", "media_type": "image/png", "data": b64 }
        }));
    }
    let text = if req.text.is_empty() { "What's on my screen?" } else { &req.text };
    parts.push(json!({ "type": "text", "text": text }));
    messages.push(json!({ "role": "user", "content": parts }));

    let mut body = json!({
        "model": route.model,
        "max_tokens": req.max_tokens,
        "messages": messages,
    });
    if stream {
        body["stream"] = json!(true);
    }
    if !req.system_prompt.is_empty() {
        body["system"] = json!(req.system_prompt);
    }
    let headers = vec![
        ("x-api-key", route.api_key.clone()),
        ("anthropic-version", "2023-06-01".to_string()),
        ("content-type", "application/json".to_string()),
    ];
    (route.endpoint.to_string(), headers, body)
}

fn openai_payload(req: &AiRequest, route: &Route, stream: bool) -> (String, Headers, Value) {
    let mut messages: Vec<Value> = vec![json!({ "role": "system", "content": req.system_prompt })];
    for (user, assistant) in &req.history {
        messages.push(json!({ "role": "user", "content": user }));
        messages.push(json!({ "role": "assistant", "content": assistant }));
    }
    let mut parts: Vec<Value> = Vec::new();
    if let Some(b64) = &req.image_base64 {
        parts.push(json!({
            "type": "image_url",
            "image_url": { "url": format!("data:image/png;base64,{b64}") }
        }));
    }
    let text = if req.text.is_empty() { "What's on my screen?" } else { &req.text };
    parts.push(json!({ "type": "text", "text": text }));
    messages.push(json!({ "role": "user", "content": parts }));

    let mut body = json!({
        "model": route.model,
        "messages": messages,
    });
    body[route.token_field] = json!(req.max_tokens);
    if stream {
        body["stream"] = json!(true);
        body["stream_options"] = json!({ "include_usage": true });
    }
    let headers = vec![
        ("authorization", format!("Bearer {}", route.api_key)),
        ("content-type", "application/json".to_string()),
    ];
    (route.endpoint.to_string(), headers, body)
}

async fn send(
    client: &reqwest::Client,
    url: &str,
    headers: Headers,
    body: &Value,
    json_accept: bool,
) -> Result<reqwest::Response, AiError> {
    let mut rb = client.post(url).json(body);
    for (k, v) in headers {
        rb = rb.header(k, v);
    }
    rb = rb.header("accept", if json_accept { "application/json" } else { "text/event-stream" });
    rb.send().await.map_err(AiError::from)
}

// ── Streaming impls ──────────────────────────────────────────────────────────

async fn stream_anthropic<F: FnMut(StreamEvent)>(
    client: &reqwest::Client,
    req: &AiRequest,
    route: &Route,
    on_event: &mut F,
) -> Result<(), AiError> {
    let (url, headers, body) = anthropic_payload(req, route, true);
    let resp = send(client, &url, headers, &body, false).await?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(AiError::Api(status, resp.text().await.unwrap_or_default()));
    }
    let mut input_tokens = 0u32;
    let mut output_tokens = 0u32;
    for_each_sse_line(resp, |payload| {
        let Ok(obj) = serde_json::from_str::<Value>(payload) else { return };
        match obj["type"].as_str() {
            Some("message_start") => {
                let u = &obj["message"]["usage"];
                input_tokens = u["input_tokens"].as_u64().unwrap_or(0) as u32;
                output_tokens = u["output_tokens"].as_u64().unwrap_or(0) as u32;
            }
            Some("content_block_delta") => {
                if let Some(t) = obj["delta"]["text"].as_str() {
                    if !t.is_empty() {
                        on_event(StreamEvent::Chunk(t.to_string()));
                    }
                }
            }
            Some("message_delta") => {
                if let Some(o) = obj["usage"]["output_tokens"].as_u64() {
                    output_tokens = o as u32;
                }
            }
            Some("message_stop") => {
                on_event(StreamEvent::Usage { input_tokens, output_tokens });
            }
            _ => {}
        }
    })
    .await
}

async fn stream_openai<F: FnMut(StreamEvent)>(
    client: &reqwest::Client,
    req: &AiRequest,
    route: &Route,
    on_event: &mut F,
) -> Result<(), AiError> {
    let (url, headers, body) = openai_payload(req, route, true);
    let resp = send(client, &url, headers, &body, false).await?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(AiError::Api(status, resp.text().await.unwrap_or_default()));
    }
    for_each_sse_line(resp, |payload| {
        if payload == "[DONE]" {
            return;
        }
        let Ok(obj) = serde_json::from_str::<Value>(payload) else { return };
        if let Some(content) = obj["choices"][0]["delta"]["content"].as_str() {
            if !content.is_empty() {
                on_event(StreamEvent::Chunk(content.to_string()));
            }
        }
        if obj["usage"].is_object() {
            let inp = obj["usage"]["prompt_tokens"].as_u64().unwrap_or(0) as u32;
            let out = obj["usage"]["completion_tokens"].as_u64().unwrap_or(0) as u32;
            on_event(StreamEvent::Usage { input_tokens: inp, output_tokens: out });
        }
    })
    .await
}

/// Read a `text/event-stream` body line by line, stripping the `data:` prefix
/// and handing each event payload to `on_payload`. Buffers raw bytes so a
/// multibyte UTF-8 char split across chunk boundaries is never decoded mid-char.
async fn for_each_sse_line<F: FnMut(&str)>(
    resp: reqwest::Response,
    mut on_payload: F,
) -> Result<(), AiError> {
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(item) = stream.next().await {
        let bytes = item?;
        buf.extend_from_slice(&bytes);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line[..line.len() - 1]);
            let line = line.trim_end_matches('\r');
            let Some(rest) = line.strip_prefix("data:") else { continue };
            let payload = rest.trim();
            if payload.is_empty() {
                continue;
            }
            on_payload(payload);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys() -> ProviderKeys {
        ProviderKeys { anthropic: "ant".into(), openai: "oai".into(), ..Default::default() }
    }

    #[test]
    fn anthropic_body_has_system_and_user_text() {
        let req = AiRequest::new("Why manhole covers round?", "claude-opus-4-8", keys())
            .system("You are terse.");
        let route = route(&req.model, &req.keys);
        let (_url, headers, body) = anthropic_payload(&req, &route, true);
        assert_eq!(body["system"], json!("You are terse."));
        assert_eq!(body["stream"], json!(true));
        assert_eq!(body["messages"][0]["role"], json!("user"));
        assert_eq!(
            body["messages"][0]["content"][0]["text"],
            json!("Why manhole covers round?")
        );
        assert!(headers.iter().any(|(k, v)| *k == "x-api-key" && v == "ant"));
    }

    #[test]
    fn openai_body_uses_correct_token_field_and_history() {
        let req = AiRequest::new("next?", "gpt-5.5", keys())
            .history(vec![("hi".into(), "hello".into())]);
        let route = route(&req.model, &req.keys);
        let (_url, headers, body) = openai_payload(&req, &route, true);
        // Reasoning models need max_completion_tokens, not max_tokens.
        assert!(body.get("max_completion_tokens").is_some());
        assert!(body.get("max_tokens").is_none());
        // system, then the history pair, then the new user message.
        assert_eq!(body["messages"][0]["role"], json!("system"));
        assert_eq!(body["messages"][1]["content"], json!("hi"));
        assert_eq!(body["messages"][2]["content"], json!("hello"));
        assert!(headers.iter().any(|(k, v)| *k == "authorization" && v == "Bearer oai"));
    }

    #[test]
    fn image_attaches_to_both_shapes() {
        let mut req = AiRequest::new("explain", "claude-opus-4-8", keys());
        req.image_base64 = Some("QUJD".into());
        let r = route(&req.model, &req.keys);
        let (_u, _h, body) = anthropic_payload(&req, &r, false);
        assert_eq!(body["messages"][0]["content"][0]["type"], json!("image"));

        let mut req2 = AiRequest::new("explain", "gpt-5.5", keys());
        req2.image_base64 = Some("QUJD".into());
        let r2 = route(&req2.model, &req2.keys);
        let (_u2, _h2, body2) = openai_payload(&req2, &r2, false);
        assert_eq!(body2["messages"][1]["content"][0]["type"], json!("image_url"));
    }
}
