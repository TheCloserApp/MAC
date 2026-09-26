import SwiftUI
import WebKit
import AVFoundation

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
        // Make sure macOS has actually granted MacOverlay mic access. The
        // WebKit content process inherits the host app's TCC grant: if the
        // host has never been prompted, every `getUserMedia` request resolves
        // to a silent stream regardless of how we answer the WKUIDelegate.
        // This call is a no-op once the user has already decided.
        Self.ensureMicPermissionRequested()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Inject a tiny diagnostic shim so we can see in Console.app whether
        // each website's `getUserMedia` call succeeds and how the resulting
        // stream looks. Helps differentiate "permission denied" from "stream
        // is silent" when audio routing seems broken.
        config.userContentController.addUserScript(Self.makeDiagnosticScript())
        config.userContentController.add(context.coordinator, name: "macoverlayMediaLog")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate         = context.coordinator
        // Right-click → Inspect Element so the user can see real errors from
        // the test website. Only available on macOS 13.3+ (we deploy 14+).
        wv.isInspectable      = true
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
        // Only drop the registry entry if it still points at *this* web
        // view. Popping the browser in or out of its own window rebuilds
        // the tab in the other host, and SwiftUI may run that host's
        // `makeNSView` before this teardown — an unconditional unregister
        // would then erase the mapping for the web view that just took
        // over, leaving the tab impossible to evict on close.
        if WebViewRegistry.shared.webView(for: coordinator.tabID) === nsView {
            WebViewRegistry.shared.unregister(for: coordinator.tabID)
        }
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "macoverlayMediaLog")
    }

    // MARK: - Permission bootstrap

    /// Trigger the macOS mic-permission prompt the first time the user opens
    /// a tab so the host app's TCC entry exists before any website asks. If
    /// the user has already decided (granted or denied), this is a no-op.
    private static func ensureMicPermissionRequested() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("[WebPanel] AVCaptureDevice mic auth status: %d", status.rawValue)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[WebPanel] AVCaptureDevice mic prompt result: %@",
                      granted ? "granted" : "denied")
            }
        case .denied, .restricted:
            NSLog("[WebPanel] mic access denied at OS level — websites will get a silent stream. " +
                  "Open System Settings → Privacy & Security → Microphone and enable TheCloser.")
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Diagnostic JS

    /// JavaScript shim injected into every page that wraps
    /// `navigator.mediaDevices.getUserMedia` and posts the outcome (track
    /// label, settings, error) back to the native side via the
    /// `macoverlayMediaLog` message handler so we can see what websites are
    /// actually getting.
    private static func makeDiagnosticScript() -> WKUserScript {
        let js = """
        (function() {
          if (window.__macoverlayMediaShim) return;
          window.__macoverlayMediaShim = true;
          const post = (msg) => {
            try { window.webkit.messageHandlers.macoverlayMediaLog.postMessage(msg); } catch (e) {}
          };
          const md = navigator.mediaDevices;
          if (!md || !md.getUserMedia) {
            post({ kind: 'no-mediaDevices' });
            return;
          }
          const orig = md.getUserMedia.bind(md);
          md.getUserMedia = async function(constraints) {
            post({ kind: 'request', constraints: JSON.stringify(constraints || {}) });
            try {
              const stream = await orig(constraints);
              const tracks = stream.getAudioTracks().map(t => ({
                label: t.label,
                muted: t.muted,
                enabled: t.enabled,
                settings: t.getSettings ? t.getSettings() : null,
              }));
              post({ kind: 'success', tracks: JSON.stringify(tracks) });
              return stream;
            } catch (err) {
              post({ kind: 'error', name: err.name, message: err.message });
              throw err;
            }
          };
        })();
        """
        return WKUserScript(source: js,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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

        // Without this, `getUserMedia({audio:true})` inside any embedded site
        // is silently denied — WKWebView treats the absence of a UI delegate
        // decision as a refusal. The host app already declares the mic
        // purpose string (NSMicrophoneUsageDescription), so the OS-level
        // prompt still gates first-time access.
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            NSLog("[WebPanel] media capture request: type=%d origin=%@://%@",
                  type.rawValue, origin.protocol, origin.host)
            decisionHandler(.grant)
        }

        // MARK: WKScriptMessageHandler — diagnostic JS bridge

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "macoverlayMediaLog",
                  let dict = message.body as? [String: Any] else { return }
            NSLog("[WebPanel][JS] %@", dict.description)
        }
    }
}
