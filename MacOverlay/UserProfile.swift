import Foundation

struct UserProfile: Codable {
    var name:        String = ""
    var currentRole: String = ""
    var company:     String = ""
}

class UserProfileManager {
    static let shared = UserProfileManager()
    private let key = "userProfile"

    func load() -> UserProfile {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        else { return UserProfile() }
        return profile
    }

    func save(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
