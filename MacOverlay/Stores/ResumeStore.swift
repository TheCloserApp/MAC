import Foundation
import Observation

@Observable
@MainActor
final class ResumeStore {
    static let shared = ResumeStore()
    private static let filename = "resumes.json"
    private static let generationsFilename = "resume-generations.json"

    var presets: [ResumePreset] {
        didSet { persist() }
    }
    var activePresetID: UUID? {
        didSet {
            UserDefaults.standard.set(activePresetID?.uuidString, forKey: "activeResumePresetID")
        }
    }
    /// Most-recent first.
    var generations: [ResumeGeneration] {
        didSet { persistGenerations() }
    }

    private init() {
        // Initialise every stored property up-front — with @Observable, any
        // mutation on `self.presets` goes through a setter method, and Swift
        // won't allow that until all stored props are initialised.
        var initialPresets = JSONStore.load([ResumePreset].self, from: Self.filename) ?? []

        // One-time migration: if the user had a single saved resumeBase before the
        // library existed, import it as "My Resume" so nothing is lost.
        if initialPresets.isEmpty {
            let legacy = UserDefaults.standard.string(forKey: "resumeBase") ?? ""
            if !legacy.isEmpty {
                initialPresets.append(ResumePreset(name: "My Resume", content: legacy))
            }
        }

        self.presets = initialPresets

        if let raw = UserDefaults.standard.string(forKey: "activeResumePresetID"),
           let uuid = UUID(uuidString: raw),
           initialPresets.contains(where: { $0.id == uuid }) {
            self.activePresetID = uuid
        } else {
            self.activePresetID = initialPresets.first?.id
        }

        self.generations = JSONStore.load([ResumeGeneration].self,
                                          from: Self.generationsFilename) ?? []
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String,
             content: String,
             tags: [String] = [],
             originalDOCX: Data? = nil,
             originalFilename: String? = nil) -> ResumePreset {
        let preset = ResumePreset(name: name, content: content, tags: tags,
                                  originalDOCX: originalDOCX,
                                  originalFilename: originalFilename)
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

    // MARK: - Generations

    /// Add a new generation row at the top of the history.
    @discardableResult
    func addGeneration(basePresetID: UUID,
                       baseText: String,
                       jd: String) -> ResumeGeneration {
        let g = ResumeGeneration(basePresetID: basePresetID, baseText: baseText, jd: jd)
        generations.insert(g, at: 0)
        return g
    }

    func updateGeneration(_ g: ResumeGeneration) {
        guard let idx = generations.firstIndex(where: { $0.id == g.id }) else { return }
        var updated = g
        updated.updatedAt = Date()
        generations[idx] = updated
    }

    func deleteGeneration(id: UUID) {
        generations.removeAll { $0.id == id }
    }

    func clearGenerations() {
        generations.removeAll()
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(presets, to: Self.filename)
    }

    private func persistGenerations() {
        JSONStore.save(generations, to: Self.generationsFilename)
    }
}
