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

    enum Role: String, Codable, Hashable { case user, assistant, system }

    init(id: UUID = UUID(),
         role: Role,
         content: String,
         timestamp: Date = Date(),
         inputTokens: Int? = nil,
         outputTokens: Int? = nil,
         model: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
    }
}

struct ChatSession: Identifiable, Codable, Hashable {
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
        case id, title, titleManuallySet, isPinned, mode,
             promptPresetID, workspaceID, turns, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id               = try c.decode(UUID.self,         forKey: .id)
        self.title            = try c.decodeIfPresent(String.self,      forKey: .title) ?? ""
        self.titleManuallySet = try c.decodeIfPresent(Bool.self,        forKey: .titleManuallySet) ?? false
        self.isPinned         = try c.decodeIfPresent(Bool.self,        forKey: .isPinned) ?? false
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
