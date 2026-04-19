import Foundation

struct PromptPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var content: String
    var linkedMode: SessionMode?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         content: String,
         linkedMode: SessionMode? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.linkedMode = linkedMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
