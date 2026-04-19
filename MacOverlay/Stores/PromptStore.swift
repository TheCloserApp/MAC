import Foundation
import Observation

@Observable
@MainActor
final class PromptStore {
    static let shared = PromptStore()
    private static let filename = "prompts.json"

    var presets: [PromptPreset] {
        didSet { persist() }
    }
    var activePresetID: UUID? {
        didSet {
            UserDefaults.standard.set(activePresetID?.uuidString, forKey: "activePromptPresetID")
        }
    }

    private init() {
        presets = JSONStore.load([PromptPreset].self, from: Self.filename) ?? PromptStore.seeded()

        // One-time migration: if the user had a legacy single customSystemPrompt
        // before the library existed, import it as "Custom" so nothing is lost.
        let legacy = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        let migrated = UserDefaults.standard.bool(forKey: "customSystemPromptMigrated")
        if !legacy.isEmpty && !migrated {
            let imported = PromptPreset(name: "Custom", content: legacy)
            presets.append(imported)
            UserDefaults.standard.set(true, forKey: "customSystemPromptMigrated")
            activePresetID = imported.id
        }

        if let raw = UserDefaults.standard.string(forKey: "activePromptPresetID"),
           let uuid = UUID(uuidString: raw),
           presets.contains(where: { $0.id == uuid }) {
            activePresetID = uuid
        }
    }

    // MARK: - CRUD

    func add(name: String, content: String, linkedMode: SessionMode? = nil) -> PromptPreset {
        let preset = PromptPreset(name: name, content: content, linkedMode: linkedMode)
        presets.append(preset)
        return preset
    }

    func update(_ preset: PromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.updatedAt = Date()
        presets[idx] = updated
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
    }

    var activePreset: PromptPreset? {
        guard let id = activePresetID else { return nil }
        return presets.first { $0.id == id }
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(presets, to: Self.filename)
    }

    // MARK: - Seed

    private static func seeded() -> [PromptPreset] {
        // Ship a handful of starter presets so the library isn't empty.
        SessionMode.allCases.map { mode in
            PromptPreset(
                name: mode.displayName,
                content: mode.systemPrompt,
                linkedMode: mode
            )
        }
    }
}
