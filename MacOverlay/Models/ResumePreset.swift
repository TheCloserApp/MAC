import Foundation

struct ResumePreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var content: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         content: String,
         tags: [String] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
