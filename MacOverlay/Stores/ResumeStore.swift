import Foundation
import Observation

@Observable
@MainActor
final class ResumeStore {
    static let shared = ResumeStore()
    private static let filename = "resumes.json"

    var presets: [ResumePreset] {
        didSet { persist() }
    }
    var activePresetID: UUID? {
        didSet {
            UserDefaults.standard.set(activePresetID?.uuidString, forKey: "activeResumePresetID")
        }
    }

    private init() {
        presets = JSONStore.load([ResumePreset].self, from: Self.filename) ?? []

        // One-time migration: if the user had a single saved resumeBase before the
        // library existed, import it as "My Resume" so nothing is lost.
        if presets.isEmpty {
            let legacy = UserDefaults.standard.string(forKey: "resumeBase") ?? ""
            if !legacy.isEmpty {
                presets.append(ResumePreset(name: "My Resume", content: legacy))
            }
        }

        if let raw = UserDefaults.standard.string(forKey: "activeResumePresetID"),
           let uuid = UUID(uuidString: raw),
           presets.contains(where: { $0.id == uuid }) {
            activePresetID = uuid
        } else {
            activePresetID = presets.first?.id
        }
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, content: String, tags: [String] = []) -> ResumePreset {
        let preset = ResumePreset(name: name, content: content, tags: tags)
        presets.append(preset)
        return preset
    }

    func update(_ preset: ResumePreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.updatedAt = Date()
        presets[idx] = updated
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = presets.first?.id }
    }

    var activePreset: ResumePreset? {
        guard let id = activePresetID else { return nil }
        return presets.first { $0.id == id }
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(presets, to: Self.filename)
    }
}
