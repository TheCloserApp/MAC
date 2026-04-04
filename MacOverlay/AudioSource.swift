enum AudioSource: Int, CaseIterable {
    case microphone = 0
    case systemAudio = 1
    case both = 2

    var label: String {
        switch self {
        case .microphone:  return "Mic"
        case .systemAudio: return "System"
        case .both:        return "Both"
        }
    }
}
