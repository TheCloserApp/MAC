import Foundation

struct ChatTurn: Identifiable, Codable, Hashable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    /// Only populated on assistant turns that went through the streaming path.
    var inputTokens: Int?
    var outputTokens: Int?
    /// Model id (e.g. `gpt-4o`, `claude-sonnet-4-6`) that produced this
    /// assistant turn. Stamped at the moment the streaming turn is
    /// created so the eyebrow label in the chat reflects the *actual*
    /// model that answered, even if the user later switches the picker.
    /// Nil for user turns and for legacy assistant turns persisted before
    /// this field existed.
    var model: String?
    /// File names attached to a user turn. Rendered as chips in the bubble.
    /// The full file content is sent to the AI as part of the prompt but
    /// is NOT stored in `content` so the chat doesn't fill with imported
    /// document text. Nil for turns saved before attachments existed.
    var attachments: [String]?
    /// The labelled attachment blocks (full extracted file text) that were
    /// prepended to this user turn's prompt. Kept out of `content` so the
    /// bubble stays readable, but replayed as context on later requests —
    /// without this the AI forgot the resume/JD after the first exchange.
    /// Nil for turns saved before this field existed.
    var hiddenContext: String?

    enum Role: String, Codable, Hashable { case user, assistant, system }

    init(id: UUID = UUID(),
         role: Role,
         content: String,
         timestamp: Date = Date(),
         inputTokens: Int? = nil,
         outputTokens: Int? = nil,
         model: String? = nil,
         attachments: [String]? = nil,
         hiddenContext: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
        self.attachments = attachments
        self.hiddenContext = hiddenContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp,
             inputTokens, outputTokens, model, attachments, hiddenContext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self,     forKey: .id)
        self.role         = try c.decode(Role.self,     forKey: .role)
        self.content      = try c.decode(String.self,   forKey: .content)
        self.timestamp    = try c.decodeIfPresent(Date.self,     forKey: .timestamp) ?? Date()
        self.inputTokens  = try c.decodeIfPresent(Int.self,      forKey: .inputTokens)
        self.outputTokens = try c.decodeIfPresent(Int.self,      forKey: .outputTokens)
        self.model        = try c.decodeIfPresent(String.self,   forKey: .model)
        self.attachments  = try c.decodeIfPresent([String].self, forKey: .attachments)
        self.hiddenContext = try c.decodeIfPresent(String.self,  forKey: .hiddenContext)
    }

    /// What the AI should see for this turn when history is replayed:
    /// the hidden attachment blocks (if any) followed by the visible text.
    /// Mirrors exactly how the original prompt was composed in `sendToAI`.
    var replayText: String {
        guard let ctx = hiddenContext, !ctx.isEmpty else { return content }
        return content.isEmpty ? ctx : "\(ctx)\n\n\(content)"
    }
}

struct ChatSession: Identifiable, Codable, Hashable {
    /// Distinguishes the flow a session came from. History buckets sessions
    /// by kind so the regular chat list isn't drowned by one-shot lookups
    /// (quickAsk) or live recording sessions (interview / regularCall).
    /// `.normal` is the legacy default — pre-segmentation sessions decode
    /// as `.normal` and bucket under "Regular call" in the History UI.
    enum Kind: String, Codable, Hashable {
        case normal, interview, regularCall, quickAsk
    }

    let id: UUID
    var title: String
    /// True once the user (or post-completion AI retitle) has explicitly named
    /// this session. Guards against the auto-title routine overwriting a
    /// user-chosen name.
    var titleManuallySet: Bool = false
    /// Pinned sessions float to the top of History and survive normal
    /// date-based sorting. Defaults to false for back-compat with older
    /// JSON stores that don't have the key.
    var isPinned: Bool = false
    var kind: Kind = .normal
    var mode: SessionMode
    var promptPresetID: UUID?
    /// The workspace this session belongs to. Optional for back-compat with
    /// sessions saved before workspaces existed — those get auto-reassigned
    /// to the default workspace at load time.
    var workspaceID: UUID?
    var turns: [ChatTurn]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String = "",
         titleManuallySet: Bool = false,
         isPinned: Bool = false,
         kind: Kind = .normal,
         mode: SessionMode = .general,
         promptPresetID: UUID? = nil,
         workspaceID: UUID? = nil,
         turns: [ChatTurn] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.titleManuallySet = titleManuallySet
        self.isPinned = isPinned
        self.kind = kind
        self.mode = mode
        self.promptPresetID = promptPresetID
        self.workspaceID = workspaceID
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Codable migration: sessions saved before `isPinned` existed decode
    // with a sensible default instead of throwing.
    private enum CodingKeys: String, CodingKey {
        case id, title, titleManuallySet, isPinned, kind, mode,
             promptPresetID, workspaceID, turns, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id               = try c.decode(UUID.self,         forKey: .id)
        self.title            = try c.decodeIfPresent(String.self,      forKey: .title) ?? ""
        self.titleManuallySet = try c.decodeIfPresent(Bool.self,        forKey: .titleManuallySet) ?? false
        self.isPinned         = try c.decodeIfPresent(Bool.self,        forKey: .isPinned) ?? false
        self.kind             = try c.decodeIfPresent(Kind.self,        forKey: .kind) ?? .normal
        self.mode             = try c.decodeIfPresent(SessionMode.self, forKey: .mode) ?? .general
        self.promptPresetID   = try c.decodeIfPresent(UUID.self,        forKey: .promptPresetID)
        self.workspaceID      = try c.decodeIfPresent(UUID.self,        forKey: .workspaceID)
        self.turns            = try c.decodeIfPresent([ChatTurn].self,  forKey: .turns) ?? []
        self.createdAt        = try c.decodeIfPresent(Date.self,        forKey: .createdAt) ?? Date()
        self.updatedAt        = try c.decodeIfPresent(Date.self,        forKey: .updatedAt) ?? Date()
    }

    /// Title auto-derived from the first user turn if not explicitly set.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let first = turns.first(where: { $0.role == .user })?.content {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(48))
        }
        return "New session"
    }

    var summary: String {
        let turnCount = turns.filter { $0.role == .user }.count
        return "\(turnCount) message\(turnCount == 1 ? "" : "s")"
    }

    /// Running totals aggregated from assistant turns' usage metadata.
    var totalInputTokens: Int  { turns.compactMap(\.inputTokens).reduce(0, +) }
    var totalOutputTokens: Int { turns.compactMap(\.outputTokens).reduce(0, +) }
    var totalTokens: Int       { totalInputTokens + totalOutputTokens }
}
