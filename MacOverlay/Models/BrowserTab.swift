import Foundation

struct BrowserTab: Identifiable {
    let id  = UUID()
    var url: URL
    var title: String = ""
}
