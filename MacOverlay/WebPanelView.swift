import SwiftUI
import WebKit

// Shared observable state between WebPanelView (NSViewRepresentable) and the toolbar
class WebViewState: ObservableObject {
    @Published var canGoBack    = false
    @Published var canGoForward = false
    @Published var currentURL   = ""
    @Published var title        = ""
    weak var webView: WKWebView?

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func sync(from wv: WKWebView) {
        canGoBack    = wv.canGoBack
        canGoForward = wv.canGoForward
        if let url = wv.url?.absoluteString, !url.isEmpty { currentURL = url }
        title = wv.title ?? ""
    }
}

struct WebPanelView: NSViewRepresentable {
    let url:   URL
    let tabID: UUID          // used to register with WebViewRegistry for peer screen share
    @ObservedObject var state: WebViewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state, tabID: tabID) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.lastLoadedURL = url
        wv.load(URLRequest(url: url))
        state.webView = wv
        // Register so peers can receive live snapshots of this tab
        WebViewRegistry.shared.register(wv, for: tabID)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        state.webView = wv
        // Re-register on every update in case the view was recycled
        WebViewRegistry.shared.register(wv, for: tabID)
        // Only reload when the URL *prop* changed, not on every state publish
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            wv.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        WebViewRegistry.shared.unregister(for: coordinator.tabID)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let state: WebViewState
        let tabID: UUID
        var lastLoadedURL: URL?

        init(state: WebViewState, tabID: UUID) {
            self.state = state
            self.tabID = tabID
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            DispatchQueue.main.async { self.state.sync(from: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.state.sync(from: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.state.sync(from: webView) }
        }
    }
}
