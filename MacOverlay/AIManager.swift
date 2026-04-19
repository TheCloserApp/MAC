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

    func isOpenAIModel(_ model: String) -> Bool {
        AIManager.openAIPrefixes.contains { model.hasPrefix($0) }
    }

    func sendMessage(
        _ text: String,
        apiKey: String,
        openAIApiKey: String,
        model: String,
        screenshot: NSImage? = nil,
        systemPrompt: String = "You are a helpful assistant. Respond helpfully and concisely.",
        history: [(user: String, assistant: String)] = []
    ) async throws -> String {
        if isOpenAIModel(model) {
            return try await sendOpenAI(text, apiKey: openAIApiKey, model: model, screenshot: screenshot, systemPrompt: systemPrompt, history: history)
        } else {
            return try await sendAnthropic(text, apiKey: apiKey, model: model, screenshot: screenshot, systemPrompt: systemPrompt, history: history)
        }
    }

    private func sendAnthropic(_ text: String, apiKey: String, model: String, screenshot: NSImage?, systemPrompt: String, history: [(user: String, assistant: String)]) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
            "model": model, "max_tokens": 1024,
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

    private func sendOpenAI(_ text: String, apiKey: String, model: String, screenshot: NSImage?, systemPrompt: String, history: [(user: String, assistant: String)]) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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

        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024,
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

    // MARK: - Streaming

    /// Streaming version of `sendMessage`. Yields `.chunk(text)` events as tokens
    /// arrive, then a single `.usage(...)` event before the stream finishes.
    func streamMessage(
        _ text: String,
        apiKey: String,
        openAIApiKey: String,
        model: String,
        screenshot: NSImage? = nil,
        systemPrompt: String = "You are a helpful assistant. Respond helpfully and concisely.",
        history: [(user: String, assistant: String)] = []
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if isOpenAIModel(model) {
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
        req.setValue(apiKey,            forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",      forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")

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
            "model": model, "max_tokens": 1024,
            "system": systemPrompt,
            "messages": messages,
            "stream": true
        ])

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
                              onEvent: (AIStreamEvent) -> Void) async throws {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw AIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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

        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024,
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
