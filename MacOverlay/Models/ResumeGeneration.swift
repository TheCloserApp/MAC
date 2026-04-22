import Foundation

/// A single "Tailor my resume against this JD" run. Captures inputs, outputs,
/// and before/after ATS scores so the Resume panel can show a history list
/// with a diff + score-delta view.
struct ResumeGeneration: Identifiable, Codable, Hashable {
    let id: UUID
    /// The resume preset this was generated from.
    let basePresetID: UUID
    /// Snapshot of the base resume text at the time of generation — needed
    /// so the diff stays correct even if the user later edits the preset.
    let baseText: String
    /// Job description text the user tailored against.
    let jd: String
    /// The tailored output.
    var generatedText: String
    /// Path to the saved DOCX file (may vanish if temp dir is cleared).
    var fileURL: URL?
    /// Score of the base resume against this JD (computed before generation).
    var beforeScore: ResumeScore?
    /// Score of the generated resume against this JD (computed after generation).
    var afterScore: ResumeScore?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         basePresetID: UUID,
         baseText: String,
         jd: String,
         generatedText: String = "",
         fileURL: URL? = nil,
         beforeScore: ResumeScore? = nil,
         afterScore: ResumeScore? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.basePresetID = basePresetID
        self.baseText = baseText
        self.jd = jd
        self.generatedText = generatedText
        self.fileURL = fileURL
        self.beforeScore = beforeScore
        self.afterScore = afterScore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Derives a human-readable title from the first line of the JD. Falls
    /// back to a timestamp so rows are never unlabelled.
    var displayTitle: String {
        let firstLine = jd
            .split(whereSeparator: { $0.isNewline })
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty {
            let f = DateFormatter()
            f.dateStyle = .short; f.timeStyle = .short
            return "Generation · \(f.string(from: createdAt))"
        }
        return String(firstLine.prefix(60))
    }

    /// +points between before and after. nil when either score is missing.
    var scoreDelta: Int? {
        guard let before = beforeScore?.score, let after = afterScore?.score
        else { return nil }
        return after - before
    }
}
