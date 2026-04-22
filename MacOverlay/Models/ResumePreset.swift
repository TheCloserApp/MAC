import Foundation

struct ResumePreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var content: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    /// Raw bytes of the original DOCX when the preset was imported from one.
    /// When present, generation uses template-based paragraph rewriting so the
    /// final DOCX keeps the original file's fonts, styles, bullets, and layout.
    var originalDOCX: Data?
    /// Exact filename the user uploaded (e.g. "AbhishekReddy.docx"). Used so
    /// the tailored output file can be saved with the same name the user
    /// recognises, rather than a synthesised temp name.
    var originalFilename: String?

    init(id: UUID = UUID(),
         name: String,
         content: String,
         tags: [String] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         originalDOCX: Data? = nil,
         originalFilename: String? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originalDOCX = originalDOCX
        self.originalFilename = originalFilename
    }
}
