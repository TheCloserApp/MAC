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
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         icon: String = "tray",
         colorHex: String = "#8E55FF",
         isDefault: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
