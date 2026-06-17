import Foundation
import AppKit

/// Emitted as a streaming response is received.
enum AIStreamEvent {
    /// A chunk of text to append to the assistant response.
    case chunk(String)
    /// Final token counts, emitted once per stream before finish.
    case usage(inputTokens: Int, outputTokens: Int)
}

class AIManager {
    static let shared = AIManager()
    private static let openAIPrefixes = ["gpt-", "o1", "o3", "o4"]

    /// Moonshot / Kimi model ids. Moonshot's API is OpenAI-compatible (same
    /// request/response shape) but lives on a different base URL and uses its
    /// own key, so it gets its own routing branch.
    private static let moonshotPrefixes = ["kimi", "moonshot-"]
    static let openAIEndpoint   = "https://api.openai.com/v1/chat/completions"
    static let moonshotEndpoint = "https://api.moonshot.ai/v1/chat/completions"

    func isOpenAIModel(_ model: String) -> Bool {
        AIManager.openAIPrefixes.contains { model.hasPrefix($0) }
    }

    func isMoonshotModel(_ model: String) -> Bool {
        AIManager.moonshotPrefixes.contains { model.hasPrefix($0) }
    }

    func sendMessage(
        _ text: String,
        apiKey: String,
        openAIApiKey: String,
        moonshotAPIKey: String = "",
        model: String,
        screenshot: NSImage? = nil,
        systemPrompt: String = "You are a helpful assistant. Respond helpfully and concisely.",
        history: [(user: String, assistant: String)] = [],
        maxTokens: Int = 1024,
        timeoutInterval: TimeInterval = 60
    ) async throws -> String {
        if isMoonshotModel(model) {
            return try await sendOpenAI(text, apiKey: moonshotAPIKey, model: model, screenshot: screenshot, systemPrompt: systemPrompt, history: history, maxTokens: maxTokens, timeoutInterval: timeoutInterval, baseURL: AIManager.moonshotEndpoint, tokenField: "max_tokens")
        } else if isOpenAIModel(model) {
            return try await sendOpenAI(text, apiKey: openAIApiKey, model: model, screenshot: screenshot, systemPrompt: systemPrompt, history: history, maxTokens: maxTokens, timeoutInterval: timeoutInterval)
        } else {
            return try await sendAnthropic(text, apiKey: apiKey, model: model, screenshot: screenshot, systemPrompt: systemPrompt, history: history, maxTokens: maxTokens, timeoutInterval: timeoutInterval)
        }
    }

    private func sendAnthropic(_ text: String, apiKey: String, model: String, screenshot: NSImage?, systemPrompt: String, history: [(user: String, assistant: String)], maxTokens: Int, timeoutInterval: TimeInterval) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutInterval
        req.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build messages: history turns first, then current message
        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user",      "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }

        var parts: [[String: Any]] = []
        if let img = screenshot, let b64 = pngBase64(from: img) {
            parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]])
        }
        parts.append(["type": "text", "text": text.isEmpty ? "What's on my screen?" : text])
        messages.append(["role": "user", "content": parts])

        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else { throw AIError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard
            let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let result  = content.first?["text"] as? String
        else { throw AIError.parseError }
        return result
    }

    private func sendOpenAI(_ text: String, apiKey: String, model: String, screenshot: NSImage?, systemPrompt: String, history: [(user: String, assistant: String)], maxTokens: Int, timeoutInterval: TimeInterval, baseURL: String = AIManager.openAIEndpoint, tokenField: String = "max_completion_tokens") async throws -> String {
        guard let url = URL(string: baseURL) else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutInterval
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build messages: system + history turns + current message
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": "user",      "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }

        var parts: [[String: Any]] = []
        if let img = screenshot, let b64 = pngBase64(from: img) {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]])
        }
        parts.append(["type": "text", "text": text.isEmpty ? "What's on my screen?" : text])
        messages.append(["role": "user", "content": parts])

        // `max_completion_tokens` replaced `max_tokens` on OpenAI Chat
        // Completions — reasoning models (o1/o3/o4, GPT-5) reject the old
        // field. Moonshot's OpenAI-compatible API still expects `max_tokens`,
        // so the field name is passed in by the caller.
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, tokenField: maxTokens,
            "messages": messages
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else { throw AIError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard
            let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let result  = choices.first?["message"] as? [String: Any],
            let text    = result["content"] as? String
        else { throw AIError.parseError }
        return text
    }

    // MARK: - Tool use (agent loop)

    /// One tool definition advertised to Claude. Supports both:
    /// - **Custom tools** — fully user-defined with a JSON-schema input.
    /// - **Built-in Anthropic tools** like `text_editor_20250429`, where
    ///   Claude is specifically trained on the tool's commands. For those,
    ///   the payload only carries `type` + `name`; Anthropic supplies the
    ///   schema and command catalogue server-side.
    struct Tool {
        let type: String?       // Anthropic built-in tool type, if applicable
        let name: String
        let description: String
        let inputSchema: [String: Any]

        /// Construct a custom tool with your own JSON-schema input.
        init(name: String, description: String, inputSchema: [String: Any]) {
            self.type = nil
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }

        /// Construct a built-in Anthropic tool (e.g. `text_editor_20250429`,
        /// `bash_20250124`). `type` is the Anthropic tool identifier; `name`
        /// is the local name you'll see in `tool_use` callbacks.
        init(builtInType: String, name: String) {
            self.type = builtInType
            self.name = name
            self.description = ""
            self.inputSchema = [:]
        }
    }

    /// Run an Anthropic tool-use loop: Claude asks to call a tool, we execute
    /// it and feed the result back, repeat until Claude stops calling tools.
    /// This is exactly how the `docx` skill works in the browser — small,
    /// verified edits with feedback at every step instead of one big blob.
    ///
    /// `handle` is called synchronously for each tool request. Returning a
    /// string means success; throwing inserts an error tool_result (Claude
    /// sees the error and can adapt).
    func sendWithTools(
        initialUserMessage: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        tools: [Tool],
        maxIterations: Int = 24,
        maxTokens: Int = 8192,
        timeoutInterval: TimeInterval = 300,
        onStatus: (@Sendable (String) -> Void)? = nil,
        handle: (_ name: String, _ input: [String: Any]) async throws -> String
    ) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.invalidURL }

        let toolsPayload: [[String: Any]] = tools.map { t in
            if let type = t.type {
                return ["type": type, "name": t.name]
            }
            return ["name": t.name, "description": t.description, "input_schema": t.inputSchema]
        }
        // Built-in tools require the computer-use beta header. Safe to set
        // unconditionally when any built-in tool is present — the server
        // ignores it for requests that don't need it.
        let hasBuiltIn = tools.contains { $0.type != nil }

        // Running transcript — we append assistant turns and user turns
        // (tool_result blocks) until Claude stops requesting tools.
        var messages: [[String: Any]] = [
            ["role": "user", "content": initialUserMessage]
        ]

        for iteration in 0..<maxIterations {
            onStatus?(iteration == 0 ? "Thinking about your résumé…" : "Thinking…")
            // History trimming: a long tool loop carries every prior turn's
            // full tool_result payload in every subsequent request. That
            // grows the input-token bill quadratically and blows past
            // per-minute rate limits. Once we've accumulated more than
            // `recentToKeep` round-trips, elide the CONTENT of older
            // tool_result blocks while keeping their structure — Claude
            // still sees the scaffolding and an "elided" marker.
            if iteration > 4 {
                messages = Self.trimOldToolResults(in: messages, recentToKeep: 4)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeoutInterval
            req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            // Layer the required betas. `computer-use-*` enables built-in
            // tools; `extended-cache-ttl-*` enables the 1-hour cache option
            // we ask for below. Comma-separating is the supported form.
            var betas: [String] = []
            if hasBuiltIn { betas.append("computer-use-2025-01-24") }
            betas.append("extended-cache-ttl-2025-04-11")
            req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
            // Prompt caching with 1-hour TTL: cost-optimises repeated runs
            // of the same résumé/JD and stretches the cache window across
            // a whole editing session instead of the default 5 min.
            var cachedMessages: [[String: Any]] = messages
            if let first = cachedMessages.first,
               (first["role"] as? String) == "user",
               let text = first["content"] as? String {
                cachedMessages[0] = [
                    "role": "user",
                    "content": [[
                        "type": "text",
                        "text": text,
                        "cache_control": ["type": "ephemeral", "ttl": "1h"]
                    ]]
                ]
            }
            let systemBlocks: [[String: Any]] = [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral", "ttl": "1h"]
            ]]
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": maxTokens,
                "system": systemBlocks,
                "tools": toolsPayload,
                "messages": cachedMessages,
            ])

            // 429 retry loop — long agent flows carry a growing conversation
            // history, so per-minute input token limits get hit often. Honour
            // the `retry-after` / `anthropic-ratelimit-*-reset` headers when
            // present, else back off exponentially (5s → 15s → 30s → 60s).
            var attempt = 0
            let maxAttempts = 6
            var data: Data = Data()
            var http: HTTPURLResponse = HTTPURLResponse()
            while true {
                let (d, r) = try await URLSession.shared.data(for: req)
                guard let h = r as? HTTPURLResponse else { throw AIError.invalidResponse }
                if h.statusCode == 200 { data = d; http = h; break }
                if h.statusCode == 429, attempt < maxAttempts {
                    let waitSec = Self.rateLimitWait(from: h, attempt: attempt)
                    onStatus?("Rate-limited — waiting \(Int(waitSec))s before retrying…")
                    try await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                    attempt += 1
                    continue
                }
                throw AIError.apiError(h.statusCode, String(data: d, encoding: .utf8) ?? "")
            }
            _ = http
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]]
            else { throw AIError.parseError }

            // Record the assistant's turn verbatim so the next call includes it.
            messages.append(["role": "assistant", "content": content])

            // Collect any tool_use blocks and execute them.
            var toolResults: [[String: Any]] = []
            var sawToolUse = false
            for block in content {
                guard let type = block["type"] as? String else { continue }
                if type == "tool_use" {
                    sawToolUse = true
                    let toolName = block["name"] as? String ?? ""
                    let toolId   = block["id"] as? String ?? ""
                    let toolInput = block["input"] as? [String: Any] ?? [:]
                    onStatus?(Self.statusLine(for: toolInput))
                    do {
                        let output = try await handle(toolName, toolInput)
                        toolResults.append([
                            "type": "tool_result",
                            "tool_use_id": toolId,
                            "content": output
                        ])
                    } catch {
                        toolResults.append([
                            "type": "tool_result",
                            "tool_use_id": toolId,
                            "content": "Error: \(error.localizedDescription)",
                            "is_error": true
                        ])
                    }
                }
            }

            // No tool calls → Claude is done. Return concatenated text blocks.
            if !sawToolUse {
                let texts = content.compactMap { $0["text"] as? String }
                return texts.joined(separator: "\n")
            }

            // Feed tool results back as the next user turn and loop.
            messages.append(["role": "user", "content": toolResults])
        }
        // Exhausted iterations. Don't throw — the caller's tool-state actor
        // may have already accumulated successful edits that we should save.
        // Return an empty string and let the caller decide what to do based
        // on whatever progress its own state tracks.
        onStatus?("Reached iteration limit — saving edits made so far.")
        return ""
    }

    /// Replace the `content` of tool_result blocks on all but the last
    /// `recentToKeep` user turns with a short "elided" stub. Keeps the
    /// conversation shape intact so Claude still sees that tools were used,
    /// but drops the payload that would otherwise balloon input tokens.
    /// Tool_results under 200 chars are left alone — they're already cheap.
    private static func trimOldToolResults(in messages: [[String: Any]],
                                           recentToKeep: Int) -> [[String: Any]] {
        var result = messages
        // Indices of user messages whose content is an array of tool_result
        // blocks (i.e. not the opening prompt, which is a plain string).
        var toolResultIndices: [Int] = []
        for (i, msg) in result.enumerated() {
            guard (msg["role"] as? String) == "user",
                  let content = msg["content"] as? [[String: Any]],
                  content.contains(where: { ($0["type"] as? String) == "tool_result" })
            else { continue }
            toolResultIndices.append(i)
        }
        guard toolResultIndices.count > recentToKeep else { return result }
        let cutoff = toolResultIndices.count - recentToKeep
        for k in 0..<cutoff {
            let idx = toolResultIndices[k]
            guard var content = result[idx]["content"] as? [[String: Any]] else { continue }
            for i in 0..<content.count {
                guard (content[i]["type"] as? String) == "tool_result",
                      let payload = content[i]["content"] as? String,
                      payload.count > 200 else { continue }
                content[i]["content"] = "(earlier tool output elided — \(payload.count) chars)"
            }
            result[idx]["content"] = content
        }
        return result
    }

    /// Translate a tool_use `input` dict into a short user-facing status line.
    /// Keeps the viewer in the loop without exposing raw XML or tool internals.
    private static func statusLine(for input: [String: Any]) -> String {
        let cmd = input["command"] as? String ?? ""
        switch cmd {
        case "view":
            if let r = input["view_range"] as? [Int], r.count >= 2 {
                return "Reviewing résumé (lines \(r[0])–\(r[1]))…"
            }
            return "Reading the résumé…"
        case "str_replace":
            let old = (input["old_str"] as? String ?? "")
            let snippet = old
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = snippet.count > 60 ? String(snippet.prefix(60)) + "…" : snippet
            if preview.isEmpty { return "Editing a section…" }
            return "Editing: “\(preview)”"
        case "insert":
            return "Adding a new bullet…"
        case "create":
            return "Rewriting the document…"
        case "undo_edit":
            return "Undoing last edit…"
        default:
            return "Working…"
        }
    }

    /// Compute how long to wait before retrying a 429. Prefers Anthropic's
    /// per-bucket reset timestamp headers when present; falls back to a
    /// capped exponential backoff so the loop always makes forward progress.
    private static func rateLimitWait(from response: HTTPURLResponse, attempt: Int) -> Double {
        // Anthropic's rate-limit reset headers are ISO-8601 timestamps.
        let resetHeaders = [
            "anthropic-ratelimit-input-tokens-reset",
            "anthropic-ratelimit-requests-reset",
            "anthropic-ratelimit-tokens-reset",
        ]
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var longestWait: TimeInterval = 0
        for key in resetHeaders {
            if let val = response.value(forHTTPHeaderField: key) {
                if let d = fmt.date(from: val) ?? ISO8601DateFormatter().date(from: val) {
                    let delta = d.timeIntervalSinceNow
                    if delta > longestWait { longestWait = delta }
                }
            }
        }
        // `retry-after` is a standard HTTP header: integer seconds.
        if let ra = response.value(forHTTPHeaderField: "retry-after"),
           let sec = Double(ra), sec > longestWait {
            longestWait = sec
        }
        if longestWait <= 0 {
            // Exponential backoff: 5, 15, 30, 60, 90, 120 seconds.
            let steps: [Double] = [5, 15, 30, 60, 90, 120]
            longestWait = steps[min(attempt, steps.count - 1)]
        }
        // Small cushion + hard cap at 2 minutes per attempt.
        return min(120, longestWait + 1)
    }

    // MARK: - Streaming

    /// Streaming version of `sendMessage`. Yields `.chunk(text)` events as tokens
    /// arrive, then a single `.usage(...)` event before the stream finishes.
    func streamMessage(
        _ text: String,
        apiKey: String,
        openAIApiKey: String,
        moonshotAPIKey: String = "",
        model: String,
        screenshot: NSImage? = nil,
        systemPrompt: String = "You are a helpful assistant. Respond helpfully and concisely.",
        history: [(user: String, assistant: String)] = []
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if isMoonshotModel(model) {
                        try await streamOpenAI(text, apiKey: moonshotAPIKey, model: model,
                                               screenshot: screenshot, systemPrompt: systemPrompt,
                                               history: history,
                                               baseURL: AIManager.moonshotEndpoint,
                                               tokenField: "max_tokens") { event in
                            continuation.yield(event)
                        }
                    } else if isOpenAIModel(model) {
                        try await streamOpenAI(text, apiKey: openAIApiKey, model: model,
                                               screenshot: screenshot, systemPrompt: systemPrompt,
                                               history: history) { event in
                            continuation.yield(event)
                        }
                    } else {
                        try await streamAnthropic(text, apiKey: apiKey, model: model,
                                                  screenshot: screenshot, systemPrompt: systemPrompt,
                                                  history: history) { event in
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamAnthropic(_ text: String, apiKey: String, model: String,
                                 screenshot: NSImage?, systemPrompt: String,
                                 history: [(user: String, assistant: String)],
                                 onEvent: (AIStreamEvent) -> Void) async throws {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Idle timeout (resets every time bytes arrive). Without it a
        // connection that silently dies mid-stream leaves the answer
        // stuck on the typing indicator until the user notices. 60s is
        // generous headroom for slow first tokens from reasoning models.
        req.timeoutInterval = 60
        req.setValue(apiKey,            forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",      forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")

        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user",      "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        // Cache breakpoints (up to 4 allowed; we use 3 with system):
        //
        // 1. End of the FIRST history pair — the session anchor. It carries
        //    the attached resume/JD/context blocks and is byte-stable for
        //    the whole session, so the expensive part of the prompt reads
        //    from cache every turn. Without this, the sliding memory
        //    window changed the prefix each turn and the multi-thousand-
        //    token anchor was re-processed uncached — the "slow with
        //    attachments" lag.
        // 2. The last history turn — incremental reuse of the recent
        //    conversation within the window.
        //
        // Below the per-model minimum cacheable size markers are ignored.
        func markCached(_ index: Int) {
            guard index >= 0, index < messages.count,
                  let text = messages[index]["content"] as? String,
                  !text.isEmpty else { return }
            messages[index]["content"] = [[
                "type": "text", "text": text,
                "cache_control": ["type": "ephemeral"],
            ] as [String: Any]]
        }
        if messages.count >= 2 {
            markCached(1)                      // anchor pair's assistant turn
        }
        if messages.count >= 4 {
            markCached(messages.count - 1)     // most recent history turn
        }
        var parts: [[String: Any]] = []
        if let img = screenshot, let b64 = pngBase64(from: img) {
            parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]])
        }
        parts.append(["type": "text", "text": text.isEmpty ? "What's on my screen?" : text])
        messages.append(["role": "user", "content": parts])

        var body: [String: Any] = [
            "model": model, "max_tokens": 2048,
            "messages": messages,
            "stream": true
        ]
        // System prompt as a cached block — empty text blocks are rejected
        // by the API, so omit the field entirely when there's no prompt.
        if !systemPrompt.isEmpty {
            body["system"] = [[
                "type": "text", "text": systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ] as [String: Any]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            // Drain body so error surfaces with detail
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AIError.apiError(http.statusCode, body)
        }

        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let jsonPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !jsonPart.isEmpty, jsonPart != "[DONE]" else { continue }
            guard let data = jsonPart.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let msg = obj["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    outputTokens = usage["output_tokens"] as? Int ?? 0
                }
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let chunk = delta["text"] as? String, !chunk.isEmpty {
                    onEvent(.chunk(chunk))
                }
            case "message_delta":
                if let usage = obj["usage"] as? [String: Any] {
                    // Anthropic reports cumulative output tokens here
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }
            case "message_stop":
                onEvent(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
            default:
                break
            }
        }
    }

    private func streamOpenAI(_ text: String, apiKey: String, model: String,
                              screenshot: NSImage?, systemPrompt: String,
                              history: [(user: String, assistant: String)],
                              baseURL: String = AIManager.openAIEndpoint,
                              tokenField: String = "max_completion_tokens",
                              onEvent: (AIStreamEvent) -> Void) async throws {
        guard let url = URL(string: baseURL) else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Idle timeout — see streamAnthropic for rationale.
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": "user",      "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        var parts: [[String: Any]] = []
        if let img = screenshot, let b64 = pngBase64(from: img) {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]])
        }
        parts.append(["type": "text", "text": text.isEmpty ? "What's on my screen?" : text])
        messages.append(["role": "user", "content": parts])

        // `max_completion_tokens` for OpenAI; Moonshot's compatible API wants
        // `max_tokens` (caller supplies the field name).
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, tokenField: 2048,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AIError.apiError(http.statusCode, body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let jsonPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !jsonPart.isEmpty else { continue }
            if jsonPart == "[DONE]" { break }
            guard let data = jsonPart.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Chunks: choices[0].delta.content
            if let choices = obj["choices"] as? [[String: Any]], let choice = choices.first,
               let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                onEvent(.chunk(content))
            }

            // Final usage: stream_options include_usage puts it on the last chunk with
            // choices == [] (newer API) or at top-level when choices absent.
            if let usage = obj["usage"] as? [String: Any] {
                let inTok  = usage["prompt_tokens"]     as? Int ?? 0
                let outTok = usage["completion_tokens"] as? Int ?? 0
                onEvent(.usage(inputTokens: inTok, outputTokens: outTok))
            }
        }
    }

    // MARK: - Helpers

    private func pngBase64(from image: NSImage) -> String? {
        guard
            let tiff   = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png    = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }
}

enum AIError: LocalizedError {
    case invalidURL, invalidResponse, apiError(Int, String), parseError
    var errorDescription: String? {
        switch self {
        case .invalidURL:             return "Invalid API URL"
        case .invalidResponse:        return "Invalid server response"
        case .apiError(let c, let m): return "API error \(c): \(m)"
        case .parseError:             return "Failed to parse API response"
        }
    }
}
