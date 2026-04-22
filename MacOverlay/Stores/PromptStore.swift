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

    /// Currently-active conversation preset (overrides the built-in mode prompt).
    var activePresetID: UUID? {
        didSet {
            UserDefaults.standard.set(activePresetID?.uuidString, forKey: "activePromptPresetID")
        }
    }
    /// Currently-active resume generation preset (overrides the default gen prompt).
    var activeResumeGenerationID: UUID? {
        didSet {
            UserDefaults.standard.set(activeResumeGenerationID?.uuidString,
                                      forKey: "activeResumeGenerationPresetID")
        }
    }
    /// Currently-active resume scoring preset.
    var activeResumeScoringID: UUID? {
        didSet {
            UserDefaults.standard.set(activeResumeScoringID?.uuidString,
                                      forKey: "activeResumeScoringPresetID")
        }
    }

    private init() {
        var loaded = JSONStore.load([PromptPreset].self, from: Self.filename) ?? PromptStore.seeded()

        // One-time migration: if the user had a legacy single customSystemPrompt
        // before the library existed, import it as "Custom" so nothing is lost.
        let legacy = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        let migrated = UserDefaults.standard.bool(forKey: "customSystemPromptMigrated")
        var restoredActive: UUID?
        if !legacy.isEmpty && !migrated {
            let imported = PromptPreset(name: "Custom", content: legacy)
            loaded.append(imported)
            UserDefaults.standard.set(true, forKey: "customSystemPromptMigrated")
            restoredActive = imported.id
        }

        self.presets = loaded

        if let uuid = restoredActive {
            self.activePresetID = uuid
        } else if let raw = UserDefaults.standard.string(forKey: "activePromptPresetID"),
                  let uuid = UUID(uuidString: raw),
                  loaded.contains(where: { $0.id == uuid }) {
            self.activePresetID = uuid
        } else {
            self.activePresetID = nil
        }

        if let raw = UserDefaults.standard.string(forKey: "activeResumeGenerationPresetID"),
           let uuid = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == uuid && $0.kind == .resumeGeneration }) {
            self.activeResumeGenerationID = uuid
        } else {
            self.activeResumeGenerationID = nil
        }

        if let raw = UserDefaults.standard.string(forKey: "activeResumeScoringPresetID"),
           let uuid = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == uuid && $0.kind == .resumeScoring }) {
            self.activeResumeScoringID = uuid
        } else {
            self.activeResumeScoringID = nil
        }
    }

    // MARK: - Filtered views

    var conversationPresets: [PromptPreset] {
        presets.filter { $0.kind == .conversation }
    }
    var resumeGenerationPresets: [PromptPreset] {
        presets.filter { $0.kind == .resumeGeneration }
    }
    var resumeScoringPresets: [PromptPreset] {
        presets.filter { $0.kind == .resumeScoring }
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String,
             content: String,
             kind: PromptPreset.Kind = .conversation,
             icon: String = "text.bubble.fill",
             colorHex: String? = nil,
             linkedMode: SessionMode? = nil) -> PromptPreset {
        let preset = PromptPreset(
            name: name, content: content, kind: kind,
            icon: icon, colorHex: colorHex, linkedMode: linkedMode
        )
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
        if activePresetID == id           { activePresetID = nil }
        if activeResumeGenerationID == id { activeResumeGenerationID = nil }
        if activeResumeScoringID == id    { activeResumeScoringID = nil }
    }

    // MARK: - Active-preset accessors

    var activePreset: PromptPreset? {
        guard let id = activePresetID else { return nil }
        return presets.first { $0.id == id }
    }
    var activeResumeGenerationPreset: PromptPreset? {
        guard let id = activeResumeGenerationID else { return nil }
        return presets.first { $0.id == id && $0.kind == .resumeGeneration }
    }
    var activeResumeScoringPreset: PromptPreset? {
        guard let id = activeResumeScoringID else { return nil }
        return presets.first { $0.id == id && $0.kind == .resumeScoring }
    }

    /// Find the user's "override" preset for a given built-in mode, if any.
    /// Picking the built-in in the top-strip mode menu auto-activates this.
    func linkedPreset(for mode: SessionMode) -> PromptPreset? {
        presets.first { $0.linkedMode == mode && $0.kind == .conversation }
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(presets, to: Self.filename)
    }

    // MARK: - Seed

    private static func seeded() -> [PromptPreset] {
        // Ship a conversation preset per built-in mode so the library isn't empty.
        SessionMode.allCases.map { mode in
            PromptPreset(
                name: mode.displayName,
                content: mode.systemPrompt,
                kind: .conversation,
                icon: mode.icon,
                linkedMode: mode
            )
        }
    }
}
