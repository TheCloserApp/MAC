import Foundation

/// A named pool of sessions. Users can group by context: "Work", "Interview
/// prep", "Client X". Each session belongs to exactly one workspace; the
/// default workspace is created on first launch and is never deletable.
struct Workspace: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// SF Symbol name shown in the switcher.
    var icon: String
    /// Hex color string, e.g. "#8E55FF". Stored as hex so it round-trips
    /// through Codable without platform-specific types.
    var colorHex: String
    /// The built-in "General" workspace can't be renamed or removed.
    var isDefault: Bool
    /// Raw values of `OverlayViewModel.PrimarySurface` cases that this
    /// workspace wants in its sidebar. Stored as strings so the model stays
    /// free of UI-layer imports. Chat is always implicitly enabled.
    var enabledFeatures: Set<String>
    var createdAt: Date
    var updatedAt: Date

    /// Every available feature except chat, which is always on.
    static let toggleableFeatures: [String] = [
        "sessions", "resumes", "prompts", "calendar", "browser"
    ]

    /// Default feature set for a brand-new workspace: everything on.
    static var defaultEnabledFeatures: Set<String> {
        Set(toggleableFeatures)
    }

    init(id: UUID = UUID(),
         name: String,
         icon: String = "tray",
         colorHex: String = "#8E55FF",
         isDefault: Bool = false,
         enabledFeatures: Set<String> = Workspace.defaultEnabledFeatures,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.isDefault = isDefault
        self.enabledFeatures = enabledFeatures
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Back-compat: workspaces saved before `enabledFeatures` existed should
    // decode as "all features on" rather than throw.
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, colorHex, isDefault, enabledFeatures, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id         = try c.decode(UUID.self,   forKey: .id)
        self.name       = try c.decode(String.self, forKey: .name)
        self.icon       = try c.decodeIfPresent(String.self, forKey: .icon)     ?? "tray"
        self.colorHex   = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#8E55FF"
        self.isDefault  = try c.decodeIfPresent(Bool.self,   forKey: .isDefault) ?? false
        self.enabledFeatures = try c.decodeIfPresent(Set<String>.self, forKey: .enabledFeatures)
            ?? Workspace.defaultEnabledFeatures
        self.createdAt  = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt  = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
