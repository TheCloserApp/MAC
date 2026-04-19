import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()
    private static let filename = "workspaces.json"

    var workspaces: [Workspace] {
        didSet { persist() }
    }
    var activeWorkspaceID: UUID {
        didSet {
            UserDefaults.standard.set(activeWorkspaceID.uuidString, forKey: "activeWorkspaceID")
        }
    }

    private init() {
        let loaded = JSONStore.load([Workspace].self, from: Self.filename) ?? []

        if loaded.isEmpty {
            // Seed a single default workspace so the UI always has one to bind to.
            let general = Workspace(name: "General",
                                    icon: "tray",
                                    colorHex: "#8E55FF",
                                    isDefault: true)
            self.workspaces = [general]
            self.activeWorkspaceID = general.id
        } else {
            self.workspaces = loaded
            if let raw = UserDefaults.standard.string(forKey: "activeWorkspaceID"),
               let uuid = UUID(uuidString: raw),
               loaded.contains(where: { $0.id == uuid }) {
                self.activeWorkspaceID = uuid
            } else {
                self.activeWorkspaceID = loaded.first!.id
            }
        }
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, icon: String = "tray", colorHex: String = "#8E55FF") -> Workspace {
        let w = Workspace(name: name, icon: icon, colorHex: colorHex, isDefault: false)
        workspaces.append(w)
        return w
    }

    func update(_ w: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == w.id }) else { return }
        var updated = w
        updated.updatedAt = Date()
        workspaces[idx] = updated
    }

    /// Deletes a workspace. The default workspace cannot be deleted. Sessions
    /// belonging to the deleted workspace are reassigned to the default so no
    /// history is lost.
    func delete(id: UUID, reassignSessions: (UUID, UUID) -> Void) {
        guard let w = workspaces.first(where: { $0.id == id }), !w.isDefault else { return }
        let defaultID = workspaces.first(where: { $0.isDefault })?.id ?? workspaces.first!.id
        reassignSessions(id, defaultID)
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id { activeWorkspaceID = defaultID }
    }

    var activeWorkspace: Workspace {
        workspaces.first { $0.id == activeWorkspaceID } ?? workspaces[0]
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(workspaces, to: Self.filename)
    }
}
