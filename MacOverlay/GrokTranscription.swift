import Foundation

/// xAI's streaming speech-to-text (Grok Voice Transcribe 2.0), the parts
/// that don't touch audio or sockets. `TranscriptionManager` streams the
/// same 16 kHz PCM it sends ElevenLabs.
///
/// Protocol (https://docs.x.ai, Speech to Text → Streaming): connect to
/// `wss://api.x.ai/v1/stt` with the key as a Bearer token, wait for
/// `transcript.created`, then send raw PCM as binary frames. The server
/// answers with `transcript.partial` events:
/// - `is_final: false`: interim text for the words still being spoken;
/// - `is_final: true, speech_final: false`: a locked chunk (about 3 s) of
///   an utterance that's still going;
/// - `speech_final: true`: the speaker stopped; the utterance is complete.
enum GrokTranscription {
    static let model = "grok-voice-transcribe-2.0"

    /// Languages xAI formats text for (numbers, currency). Others are sent
    /// without a language and transcribed as spoken.
    static let formattedLanguages: Set<String> = [
        "ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi", "id", "it", "ja", "ko",
        "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi",
    ]

    /// 600 ms of silence ends an utterance, the same pause ElevenLabs waits
    /// for, so switching engines doesn't change when answers start.
    static func streamURL(language: String) -> URL? {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")
        var query = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "600"),
        ]
        if formattedLanguages.contains(language) {
            query.append(URLQueryItem(name: "language", value: language))
        }
        components?.queryItems = query
        return components?.url
    }

    struct Event: Decodable {
        let type: String
        let text: String?
        let is_final: Bool?
        let speech_final: Bool?
        let message: String?

        static func parse(_ json: String) -> Event? {
            try? JSONDecoder().decode(Event.self, from: Data(json.utf8))
        }
    }

    /// Turns partial events into what the app shows and commits: the
    /// current utterance so far, and each finished utterance once.
    struct Utterance {
        /// Chunks of the current utterance that the server has locked.
        private(set) var locked: [String] = []

        enum Output: Equatable {
            /// The current utterance so far, for the live transcript.
            case partial(String)
            /// A finished utterance.
            case commit(String)
        }

        mutating func handle(_ event: Event) -> Output? {
            guard event.type == "transcript.partial" else { return nil }
            let text = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if event.speech_final == true {
                let full = Self.stitch(locked: locked, final: text)
                locked = []
                return .commit(full)
            }
            if event.is_final == true {
                if !text.isEmpty { locked.append(text) }
                return .partial(locked.joined(separator: " "))
            }
            let soFar = (locked + [text]).filter { !$0.isEmpty }.joined(separator: " ")
            return soFar.isEmpty ? nil : .partial(soFar)
        }

        /// The final event is documented as the whole stitched utterance.
        /// If it turns out to hold only the last chunk, put the locked
        /// chunks back in front of it rather than lose them.
        static func stitch(locked: [String], final: String) -> String {
            let before = locked.joined(separator: " ")
            guard !before.isEmpty else { return final }
            guard !final.isEmpty else { return before }
            let simplified = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
            if simplified(final).hasPrefix(simplified(before)) { return final }
            return before + " " + final
        }
    }
}
