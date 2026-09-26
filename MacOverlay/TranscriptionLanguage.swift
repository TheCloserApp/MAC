import Foundation

/// The language speech is transcribed in, shared by every engine (Apple,
/// ElevenLabs, Quick Ask, dictation).
///
/// Defaults to English. Apple's recognizer used to follow the Mac's system
/// language, so on a Mac set to another language an English interview came
/// out as that language.
struct TranscriptionLanguage: Identifiable, Hashable {
    /// Apple locale identifier, e.g. "en-IN".
    let id: String
    let name: String
    /// ISO 639-1 code sent to ElevenLabs Scribe.
    let elevenLabsCode: String

    var locale: Locale { Locale(identifier: id) }

    static let all: [TranscriptionLanguage] = [
        .init(id: "en-US", name: "English (US)",        elevenLabsCode: "en"),
        .init(id: "en-GB", name: "English (UK)",        elevenLabsCode: "en"),
        .init(id: "en-IN", name: "English (India)",     elevenLabsCode: "en"),
        .init(id: "en-AU", name: "English (Australia)", elevenLabsCode: "en"),
        .init(id: "en-CA", name: "English (Canada)",    elevenLabsCode: "en"),
        .init(id: "es-ES", name: "Spanish (Spain)",     elevenLabsCode: "es"),
        .init(id: "es-MX", name: "Spanish (Mexico)",    elevenLabsCode: "es"),
        .init(id: "fr-FR", name: "French",              elevenLabsCode: "fr"),
        .init(id: "de-DE", name: "German",              elevenLabsCode: "de"),
        .init(id: "it-IT", name: "Italian",             elevenLabsCode: "it"),
        .init(id: "pt-BR", name: "Portuguese (Brazil)", elevenLabsCode: "pt"),
        .init(id: "nl-NL", name: "Dutch",               elevenLabsCode: "nl"),
        .init(id: "hi-IN", name: "Hindi",               elevenLabsCode: "hi"),
        .init(id: "ja-JP", name: "Japanese",            elevenLabsCode: "ja"),
        .init(id: "ko-KR", name: "Korean",              elevenLabsCode: "ko"),
        .init(id: "zh-CN", name: "Chinese (Mandarin)",  elevenLabsCode: "zh"),
    ]

    static let defaultsKey = "transcriptionLanguage"

    static func language(for id: String?) -> TranscriptionLanguage? {
        all.first { $0.id == id }
    }

    /// English, in the Mac's own English variant when we have it (so an
    /// en-IN or en-GB Mac keeps its accent model), otherwise US English.
    /// Never the system language itself: a French Mac still gets English.
    static func defaultLanguage(for locale: Locale) -> TranscriptionLanguage {
        if locale.language.languageCode?.identifier == "en",
           let region = locale.region?.identifier,
           let match = language(for: "en-\(region)") {
            return match
        }
        return all[0]
    }

    /// The saved choice, or the default if nothing valid is saved.
    static var current: TranscriptionLanguage {
        language(for: UserDefaults.standard.string(forKey: defaultsKey))
            ?? defaultLanguage(for: .current)
    }
}
