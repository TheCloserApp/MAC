import Foundation

/// A named, saved system prompt. Can be one of three kinds — a chat/session
/// prompt, a resume-generation prompt, or a resume-scoring prompt — so a
/// single store can back all three "prompt library" surfaces.
struct PromptPreset: Identifiable, Codable, Hashable {

    enum Kind: String, Codable, Hashable, CaseIterable {
        /// Used as the system prompt for chat / interview / meeting sessions.
        case conversation
        /// Override for the resume-generation system prompt.
        case resumeGeneration
        /// Override for the resume-scoring system prompt.
        case resumeScoring

        var displayName: String {
            switch self {
            case .conversation:     return "Conversation"
            case .resumeGeneration: return "Resume generation"
            case .resumeScoring:    return "Resume scoring"
            }
        }
    }

    let id: UUID
    var name: String
    var content: String
    var kind: Kind
    /// SF Symbol name shown when this preset acts as a mode pill.
    var icon: String
    /// Hex color (e.g. "#FF00AA") for the mode badge when active. Nil falls
    /// back to the linked mode's default color (or accent).
    var colorHex: String?
    /// If set, this preset is treated as the default prompt for that
    /// session mode — picking the built-in mode auto-activates this preset.
    var linkedMode: SessionMode?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         content: String,
         kind: Kind = .conversation,
         icon: String = "text.bubble.fill",
         colorHex: String? = nil,
         linkedMode: SessionMode? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.kind = kind
        self.icon = icon
        self.colorHex = colorHex
        self.linkedMode = linkedMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Codable migration: presets saved before `kind`/`icon`/`colorHex` existed
    // still decode cleanly by falling back to sensible defaults.
    private enum CodingKeys: String, CodingKey {
        case id, name, content, kind, icon, colorHex, linkedMode, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self,   forKey: .id)
        self.name        = try c.decode(String.self, forKey: .name)
        self.content     = try c.decode(String.self, forKey: .content)
        self.kind        = try c.decodeIfPresent(Kind.self,        forKey: .kind)       ?? .conversation
        self.icon        = try c.decodeIfPresent(String.self,      forKey: .icon)       ?? "text.bubble.fill"
        self.colorHex    = try c.decodeIfPresent(String.self,      forKey: .colorHex)
        self.linkedMode  = try c.decodeIfPresent(SessionMode.self, forKey: .linkedMode)
        self.createdAt   = try c.decodeIfPresent(Date.self,        forKey: .createdAt) ?? Date()
        self.updatedAt   = try c.decodeIfPresent(Date.self,        forKey: .updatedAt) ?? Date()
    }
}
