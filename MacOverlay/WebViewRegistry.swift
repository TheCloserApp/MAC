import WebKit

/// Maps each browser tab's UUID to its live WKWebView instance.
/// Used by PeerControlServer to take snapshots and inject events.
/// All access must happen on the main thread.
class WebViewRegistry {
    static let shared = WebViewRegistry()
    private var registry: [UUID: WKWebView] = [:]
    private init() {}

    func register(_ webView: WKWebView, for id: UUID) {
        registry[id] = webView
    }

    func unregister(for id: UUID) {
        registry.removeValue(forKey: id)
    }

    func webView(for id: UUID) -> WKWebView? {
        registry[id]
    }
}
