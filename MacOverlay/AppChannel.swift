import Foundation

/// Which build of the app is running: Dev, Beta or Production.
///
/// `build.sh --channel` writes the channel into Info.plist under `TCChannel`
/// and gives each channel its own bundle ID, app name and executable, so all
/// three can be installed side by side with separate settings, data and
/// privacy permissions. A bundle without the key counts as production.
enum AppChannel: String, CaseIterable {
    case dev
    case beta
    case production = "prod"

    static let current = AppChannel(infoValue: Bundle.main.object(forInfoDictionaryKey: "TCChannel"))

    init(infoValue: Any?) {
        self = (infoValue as? String).flatMap(AppChannel.init(rawValue:)) ?? .production
    }

    /// Dev and Beta turn on features that haven't graduated to production.
    var showsPreviewFeatures: Bool { self != .production }

    /// Label shown on the brand pill so side-by-side builds are easy to tell
    /// apart. Production shows none.
    var badge: String? {
        switch self {
        case .dev:        return "DEV"
        case .beta:       return "BETA"
        case .production: return nil
        }
    }

    /// Suffix appended to user-visible names ("thecloser Beta").
    var nameSuffix: String {
        switch self {
        case .dev:        return " Dev"
        case .beta:       return " Beta"
        case .production: return ""
        }
    }

    /// Folder under ~/Library/Application Support. Production keeps the
    /// original name so existing users' sessions and prompts carry over.
    var dataDirectoryName: String { "MacOverlay" + nameSuffix }
}
