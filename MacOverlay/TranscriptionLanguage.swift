import Foundation

/// The language speech is transcribed in, shared by every engine (Apple,
/// ElevenLabs, Quick Ask, dictation).
///
/// Defaults to English. Apple's recognizer used to follow the Mac's system
/// language, so on a Mac set to another language an English interview came
/// out as that language.
///
/// Grok transcribes whatever it hears (its language parameter only formats
/// numbers), so text written in a script the chosen language doesn't use —
/// Telugu while English is picked, say — is ignored, as on Windows. Indian
/// languages also allow Latin, since they're routinely mixed with English.
/// Apple's recognizer doesn't do most Indian languages; those need
/// ElevenLabs or Grok.
struct TranscriptionLanguage: Identifiable, Hashable {
    /// Apple locale identifier, e.g. "en-IN".
    let id: String
    let name: String
    /// ISO 639-1 code sent to ElevenLabs Scribe.
    let elevenLabsCode: String
    /// Writing systems a transcript in this language uses.
    let scripts: [String]

    var locale: Locale { Locale(identifier: id) }
    /// "English" for "English (US)", for messages.
    var shortName: String { name.components(separatedBy: " (").first ?? name }

    static let all: [TranscriptionLanguage] = [
        .init(id: "en-US", name: "English (US)",        elevenLabsCode: "en", scripts: ["Latin"]),
        .init(id: "en-GB", name: "English (UK)",        elevenLabsCode: "en", scripts: ["Latin"]),
        .init(id: "en-IN", name: "English (India)",     elevenLabsCode: "en", scripts: ["Latin"]),
        .init(id: "en-AU", name: "English (Australia)", elevenLabsCode: "en", scripts: ["Latin"]),
        .init(id: "en-CA", name: "English (Canada)",    elevenLabsCode: "en", scripts: ["Latin"]),
        .init(id: "es-ES", name: "Spanish (Spain)",     elevenLabsCode: "es", scripts: ["Latin"]),
        .init(id: "es-MX", name: "Spanish (Mexico)",    elevenLabsCode: "es", scripts: ["Latin"]),
        .init(id: "fr-FR", name: "French",              elevenLabsCode: "fr", scripts: ["Latin"]),
        .init(id: "de-DE", name: "German",              elevenLabsCode: "de", scripts: ["Latin"]),
        .init(id: "it-IT", name: "Italian",             elevenLabsCode: "it", scripts: ["Latin"]),
        .init(id: "pt-BR", name: "Portuguese (Brazil)", elevenLabsCode: "pt", scripts: ["Latin"]),
        .init(id: "nl-NL", name: "Dutch",               elevenLabsCode: "nl", scripts: ["Latin"]),
        .init(id: "hi-IN", name: "Hindi",               elevenLabsCode: "hi", scripts: ["Devanagari", "Latin"]),
        .init(id: "te-IN", name: "Telugu",              elevenLabsCode: "te", scripts: ["Telugu", "Latin"]),
        .init(id: "ta-IN", name: "Tamil",               elevenLabsCode: "ta", scripts: ["Tamil", "Latin"]),
        .init(id: "kn-IN", name: "Kannada",             elevenLabsCode: "kn", scripts: ["Kannada", "Latin"]),
        .init(id: "ml-IN", name: "Malayalam",           elevenLabsCode: "ml", scripts: ["Malayalam", "Latin"]),
        .init(id: "mr-IN", name: "Marathi",             elevenLabsCode: "mr", scripts: ["Devanagari", "Latin"]),
        .init(id: "bn-IN", name: "Bengali",             elevenLabsCode: "bn", scripts: ["Bengali", "Latin"]),
        .init(id: "gu-IN", name: "Gujarati",            elevenLabsCode: "gu", scripts: ["Gujarati", "Latin"]),
        .init(id: "pa-IN", name: "Punjabi",             elevenLabsCode: "pa", scripts: ["Gurmukhi", "Latin"]),
        .init(id: "ur-PK", name: "Urdu",                elevenLabsCode: "ur", scripts: ["Arabic", "Latin"]),
        .init(id: "ja-JP", name: "Japanese",            elevenLabsCode: "ja", scripts: ["Kana", "Han"]),
        .init(id: "ko-KR", name: "Korean",              elevenLabsCode: "ko", scripts: ["Hangul"]),
        .init(id: "zh-CN", name: "Chinese (Mandarin)",  elevenLabsCode: "zh", scripts: ["Han"]),
    ]

    /// Whether `text` is (mostly) written in this language's scripts.
    /// Digits, punctuation and a stray foreign word don't count against it.
    func matches(_ text: String) -> Bool {
        var total = 0, ok = 0
        for scalar in text.unicodeScalars {
            guard let script = Self.script(of: scalar) else { continue }
            total += 1
            if scripts.contains(script) { ok += 1 }
        }
        return total == 0 || ok * 2 >= total
    }

    /// The writing system of a character, or nil for digits, punctuation
    /// and spaces. Same ranges as the Windows app.
    static func script(of scalar: Unicode.Scalar) -> String? {
        let v = scalar.value
        switch v {
        case ..<0x0250:        return scalar.properties.isAlphabetic ? "Latin" : nil
        case 0x1E00...0x1EFF:  return "Latin"   // Vietnamese and other accented Latin
        case 0x0400...0x052F:  return "Cyrillic"
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "Arabic"
        case 0x0900...0x097F:  return "Devanagari"
        case 0x0980...0x09FF:  return "Bengali"
        case 0x0A00...0x0A7F:  return "Gurmukhi"
        case 0x0A80...0x0AFF:  return "Gujarati"
        case 0x0B80...0x0BFF:  return "Tamil"
        case 0x0C00...0x0C7F:  return "Telugu"
        case 0x0C80...0x0CFF:  return "Kannada"
        case 0x0D00...0x0D7F:  return "Malayalam"
        case 0x0E00...0x0E7F:  return "Thai"
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return "Kana"
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return "Hangul"
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return "Han"
        default:               return scalar.properties.isAlphabetic ? "Other" : nil
        }
    }

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
