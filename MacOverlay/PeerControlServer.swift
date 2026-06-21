import Foundation
import Network
import WebKit

// MARK: - Peer Control Server
//
// Runs a lightweight local HTTP server so a trusted peer (colleague, coach, etc.)
// can view the live overlay state and send commands from any browser on the same
// network.
//
// Usage:
//   1. Call start() to begin listening (OS assigns a free port).
//   2. Share connectionURL (includes embedded access code).
//   3. The peer opens the URL — the web page auto-authenticates and shows a
//      live control panel (SSE-driven, no polling).
//   4. Call stop() to shut down.

class PeerControlServer: ObservableObject, @unchecked Sendable {
    static let shared = PeerControlServer()

    @Published var isRunning    = false
    @Published var port:       UInt16 = 0
    @Published var accessCode: String
    @Published var connectedPeers: Int = 0

    weak var viewModel: OverlayViewModel?

    private var listener: NWListener?
    // All keys / mutations happen on main thread only
    private var sseConnections: [UUID: NWConnection] = [:]
    private let q = DispatchQueue(label: "com.macoverlay.peer", qos: .userInitiated)
    // CORS header reused across all responses
    private let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-Access-Code\r\n"

    private init() {
        accessCode = String(format: "%06d", Int.random(in: 100_000...999_999))
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params)

            listener?.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.q)
                let id = UUID()
                self.readRequest(conn, id: id)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port      = self.listener?.port?.rawValue ?? 0
                        self.isRunning = true
                    case .failed:
                        self.isRunning = false
                    default: break
                    }
                }
            }
            listener?.start(queue: q)
        } catch {
            print("[PeerServer] start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sseConnections.values.forEach { $0.cancel() }
        sseConnections.removeAll()
        isRunning     = false
        port          = 0
        connectedPeers = 0
    }

    // MARK: - State broadcast (@MainActor — called from ViewModel Combine sinks on main)

    @MainActor
    func broadcastState() {
        guard !sseConnections.isEmpty else { return }
        let json    = stateJSON()
        guard let data = "data: \(json)\n\n".data(using: .utf8) else { return }

        for (id, conn) in sseConnections {
            conn.send(content: data, completion: .contentProcessed { [weak self] err in
                guard err != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.sseConnections.removeValue(forKey: id)
                    self?.connectedPeers = self?.sseConnections.count ?? 0
                }
            })
        }
    }

    // MARK: - State snapshot (@MainActor — reads VM properties safely)

    @MainActor
    private func stateJSON() -> String {
        let vm = viewModel
        // Serialise browser tabs so peers can display and control them
        let tabsData: [[String: Any]] = vm?.browserTabs.map { t in
            [
                "id":       t.id.uuidString,
                "title":    t.title.isEmpty ? (t.url.host ?? "Tab") : t.title,
                "url":      t.url.absoluteString,
                "isActive": t.id == vm?.activeTabID
            ]
        } ?? []
        let browserData: [String: Any] = [
            "isOpen": vm?.hasBrowser ?? false,
            "tabs":   tabsData
        ]
        let d: [String: Any] = [
            "transcription":  vm?.transcription  ?? "",
            "aiResponse":     vm?.aiResponse     ?? "",
            "isSendingToAI":  vm?.isSendingToAI  ?? false,
            "isRecording":    vm?.isRecording     ?? false,
            "sessionMode":    vm?.sessionMode.rawValue ?? "general",
            "statusMessage":  vm?.statusMessage  ?? "",
            "quickActions":   vm?.sessionMode.quickActions.map { $0.label } ?? [],
            "browser":        browserData,
            "peerMessage":    vm?.peerMessage    ?? ""   // echoed back so peer sees "received" state
        ]
        guard let raw = try? JSONSerialization.data(withJSONObject: d),
              let str = String(data: raw, encoding: .utf8) else { return "{}" }
        return str
    }

    // MARK: - HTTP receive (background queue)

    private func readRequest(_ conn: NWConnection, id: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, done, err in
            guard let self else { conn.cancel(); return }
            if let data, !data.isEmpty, let raw = String(data: data, encoding: .utf8) {
                // Route on MainActor so it can safely access ViewModel and sseConnections
                Task { @MainActor [weak self] in self?.route(raw, conn: conn, id: id) }
            } else if done || err != nil {
                conn.cancel()
            }
        }
    }

    // MARK: - Router (@MainActor)

    @MainActor
    private func route(_ raw: String, conn: NWConnection, id: UUID) {
        let lines  = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { conn.cancel(); return }
        let parts  = first.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }

        let method = parts[0]
        let full   = parts[1]
        let qi     = full.firstIndex(of: "?")
        let path   = qi.map { String(full[full.startIndex..<$0]) } ?? full
        let query  = qi.map { String(full[full.index(after: $0)...]) } ?? ""

        // Parse headers
        var hdrs: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let ci = line.firstIndex(of: ":") {
                let k = String(line[..<ci]).lowercased()
                let v = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                hdrs[k] = v
            }
        }

        // Parse body (everything after blank line)
        let body = raw.range(of: "\r\n\r\n").map { String(raw[$0.upperBound...]) } ?? ""

        // Resolve access code (header takes priority over query param)
        let headerCode = hdrs["x-access-code"] ?? ""
        let code       = headerCode.isEmpty ? qParam(query, "code") : headerCode

        if method == "OPTIONS" {
            txt("HTTP/1.1 200 OK\r\n\(cors)Content-Length: 0\r\n\r\n", conn: conn)
            return
        }

        // The root HTML page is public (the code is embedded in the URL the host shares)
        if method == "GET" && path == "/" {
            serveHTML(conn)
            return
        }

        // All other endpoints require authentication
        guard code == accessCode else {
            txt("HTTP/1.1 403 Forbidden\r\n\(cors)Content-Type: text/plain\r\nContent-Length: 12\r\n\r\nInvalid code", conn: conn)
            return
        }

        switch (method, path) {

        case ("GET", "/state"):
            let j = stateJSON()
            guard let d = (j + "\n").data(using: .utf8) else { conn.cancel(); return }
            var r = "HTTP/1.1 200 OK\r\n\(cors)Content-Type: application/json\r\nContent-Length: \(d.count)\r\n\r\n".data(using: .utf8)!
            r.append(d)
            conn.send(content: r, completion: .contentProcessed { _ in conn.cancel() })

        case ("GET", "/events"):
            // Upgrade to SSE stream — keep connection open
            let header = "HTTP/1.1 200 OK\r\n\(cors)Content-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            conn.send(content: header.data(using: .utf8)!, completion: .idempotent)
            sseConnections[id] = conn
            connectedPeers      = sseConnections.count
            // Push initial state immediately
            let init_ = "data: \(stateJSON())\n\n"
            conn.send(content: init_.data(using: .utf8)!, completion: .idempotent)

        case ("POST", "/action"):
            processAction(body)
            txt("HTTP/1.1 200 OK\r\n\(cors)Content-Length: 2\r\n\r\nOK", conn: conn)

        // JPEG snapshot of the active browser tab's WebView
        case ("GET", "/snapshot"):
            handleSnapshot(conn)

        // Mouse / scroll events forwarded into the active WebView
        case ("POST", "/webview-event"):
            handleWebViewEvent(body, conn: conn)

        default:
            txt("HTTP/1.1 404 Not Found\r\n\(cors)Content-Length: 9\r\n\r\nNot Found", conn: conn)
        }
    }

    // MARK: - Action dispatch (@MainActor)

    @MainActor
    private func processAction(_ body: String) {
        guard
            let vm   = viewModel,
            let d    = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "send":
            let txt = (json["payload"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { return }
            // Stage for local user review — DO NOT auto-send to AI
            vm.peerMessage = txt

        case "clearTranscription":
            vm.transcription = ""

        case "clearResponse":
            vm.aiResponse = ""

        case "setMode":
            if let raw = json["payload"] as? String, let m = SessionMode(rawValue: raw) {
                vm.sessionMode = m
            }

        case "quickAction":
            if let label  = json["payload"] as? String,
               let action = vm.sessionMode.quickActions.first(where: { $0.label == label }) {
                vm.selectQuickAction(action)
            }

        // ── Browser actions ────────────────────────────────────────────

        case "toggleBrowser":
            vm.toggleBrowser()

        case "browserNavigate":
            var raw = (json["payload"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            if !raw.contains("://") { raw = "https://" + raw }
            if let url = URL(string: raw) { vm.navigateActiveTab(to: url) }

        case "browserNewTab":
            var raw = (json["payload"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { raw = "https://www.google.com" }
            if !raw.contains("://") { raw = "https://" + raw }
            if let url = URL(string: raw) { vm.addTab(url: url) }

        case "browserCloseTab":
            if let s = json["payload"] as? String, let uuid = UUID(uuidString: s) {
                vm.closeTab(id: uuid)
            }

        case "browserSwitchTab":
            if let s = json["payload"] as? String, let uuid = UUID(uuidString: s) {
                vm.switchTab(id: uuid)
            }

        default: break
        }
    }

    // MARK: - Snapshot endpoint (@MainActor — WKWebView.takeSnapshot must run on main)

    @MainActor
    private func handleSnapshot(_ conn: NWConnection) {
        guard
            let vm      = viewModel,
            vm.hasBrowser,
            let activeID = vm.activeTabID,
            let wv      = WebViewRegistry.shared.webView(for: activeID)
        else {
            // No browser open — return a small grey placeholder PNG
            txt("HTTP/1.1 204 No Content\r\n\(cors)\r\n", conn: conn)
            return
        }

        let cfg      = WKSnapshotConfiguration()
        cfg.rect     = CGRect(origin: .zero, size: wv.bounds.size)

        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self else { conn.cancel(); return }
            if let image, let jpg = self.toJPEG(image) {
                var r = "HTTP/1.1 200 OK\r\n\(self.cors)Content-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\nCache-Control: no-store, no-cache\r\n\r\n"
                    .data(using: .utf8)!
                r.append(jpg)
                conn.send(content: r, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                self.txt("HTTP/1.1 204 No Content\r\n\(self.cors)\r\n", conn: conn)
            }
        }
    }

    private func toJPEG(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.65)])
    }

    // MARK: - WebView event injection (@MainActor)

    @MainActor
    private func handleWebViewEvent(_ body: String, conn: NWConnection) {
        defer { txt("HTTP/1.1 200 OK\r\n\(cors)Content-Length: 2\r\n\r\nOK", conn: conn) }
        guard
            let vm      = viewModel,
            vm.hasBrowser,
            let activeID = vm.activeTabID,
            let wv      = WebViewRegistry.shared.webView(for: activeID),
            let data    = body.data(using: .utf8),
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type    = json["type"] as? String
        else { return }

        switch type {
        case "click":
            let relX = json["relX"] as? Double ?? 0
            let relY = json["relY"] as? Double ?? 0
            let vx   = relX * Double(wv.bounds.width)
            let vy   = relY * Double(wv.bounds.height)
            // Dispatch a synthetic click at the viewport coordinate
            let js = """
            (function(){
              var el = document.elementFromPoint(\(vx), \(vy));
              if(el){
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(vx),clientY:\(vy)}));
                el.dispatchEvent(new MouseEvent('mouseup',  {bubbles:true,cancelable:true,clientX:\(vx),clientY:\(vy)}));
                el.dispatchEvent(new MouseEvent('click',    {bubbles:true,cancelable:true,clientX:\(vx),clientY:\(vy)}));
                if(el.tagName==='A' && el.href) window.location.href = el.href;
              }
            })();
            """
            wv.evaluateJavaScript(js, completionHandler: nil)

        case "scroll":
            let dx   = json["dx"]   as? Double ?? 0
            let dy   = json["dy"]   as? Double ?? 0
            let relX = json["relX"] as? Double ?? 0.5
            let relY = json["relY"] as? Double ?? 0.5
            let vx   = relX * Double(wv.bounds.width)
            let vy   = relY * Double(wv.bounds.height)
            let scrollJS = """
            (function(){
              var vx=\(vx),vy=\(vy),dx=\(dx),dy=\(dy);
              var el=document.elementFromPoint(vx,vy);
              while(el && el!==document.documentElement){
                var st=window.getComputedStyle(el);
                var oy=st.overflowY,ox=st.overflowX;
                var sy=(oy==='auto'||oy==='scroll')&&el.scrollHeight>el.clientHeight;
                var sx=(ox==='auto'||ox==='scroll')&&el.scrollWidth>el.clientWidth;
                if(sy||sx){ el.scrollBy(dx,dy); return; }
                el=el.parentElement;
              }
              window.scrollBy(dx,dy);
            })();
            """
            wv.evaluateJavaScript(scrollJS, completionHandler: nil)

        case "keypress":
            // Best-effort: dispatch a KeyboardEvent then insertText for printable characters
            let key   = (json["key"] as? String ?? "").replacingOccurrences(of: "\\", with: "\\\\")
                                                       .replacingOccurrences(of: "\"", with: "\\\"")
            let code  = (json["code"] as? String ?? "")
            let js = """
            (function(){
              var el = document.activeElement || document.body;
              var opts = {key:"\(key)",code:"\(code)",bubbles:true,cancelable:true};
              el.dispatchEvent(new KeyboardEvent('keydown',opts));
              el.dispatchEvent(new KeyboardEvent('keypress',opts));
              if("\(key)".length===1){
                document.execCommand('insertText',false,"\(key)");
              } else if("\(key)"==="Backspace"){
                document.execCommand('delete',false);
              } else if("\(key)"==="Enter"){
                el.dispatchEvent(new KeyboardEvent('keyup',opts));
                if(el.form) el.form.dispatchEvent(new Event('submit',{bubbles:true}));
              }
              el.dispatchEvent(new KeyboardEvent('keyup',opts));
            })();
            """
            wv.evaluateJavaScript(js, completionHandler: nil)

        default: break
        }
    }

    // MARK: - Helpers

    private func qParam(_ query: String, _ key: String) -> String {
        query.components(separatedBy: "&").compactMap {
            let kv = $0.components(separatedBy: "=")
            guard kv.count == 2, kv[0] == key else { return nil }
            return kv[1].removingPercentEncoding ?? kv[1]
        }.first ?? ""
    }

    private func txt(_ s: String, conn: NWConnection) {
        conn.send(content: s.data(using: .utf8)!, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveHTML(_ conn: NWConnection) {
        let html = webPage()
        guard let body = html.data(using: .utf8) else { conn.cancel(); return }
        let h = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var d = h.data(using: .utf8)!
        d.append(body)
        conn.send(content: d, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Local IP

    func localIP() -> String {
        var result = "127.0.0.1"
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return result }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let addr = cur.pointee.ifa_addr else { continue }
            // Skip loopback; only show UP+RUNNING interfaces
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(NI_MAXHOST),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                break
            }
        }
        return result
    }

    var connectionURL: String {
        guard isRunning, port > 0 else { return "" }
        return "http://\(localIP()):\(port)/?code=\(accessCode)"
    }

    // MARK: - Embedded web page

    private func webPage() -> String {
        // Raw HTML + JS served to the peer's browser.
        // The page auto-reads ?code= from the URL so the host just
        // shares the connectionURL and the peer sees the panel immediately.
        return #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>thecloser — Peer Control</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d0d12;color:#e2e8f0;min-height:100vh}
.topbar{background:rgba(255,255,255,.04);border-bottom:1px solid rgba(255,255,255,.07);padding:12px 16px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:20;backdrop-filter:blur(12px)}
.logo{font-size:14px;font-weight:700;letter-spacing:-.4px;color:#f1f5f9}
.logo span{color:#818cf8}
.badge{display:inline-flex;align-items:center;gap:5px;font-size:11px;font-weight:600;padding:4px 10px;border-radius:20px;border:1px solid}
.badge-conn{color:#34d399;border-color:rgba(52,211,153,.3);background:rgba(52,211,153,.08)}
.badge-disc{color:#f87171;border-color:rgba(248,113,113,.3);background:rgba(248,113,113,.08)}
.badge-dot{width:6px;height:6px;border-radius:50%;background:currentColor}
.wrap{max-width:720px;margin:0 auto;padding:16px 14px 52px}
.section{margin-bottom:13px}
.card{background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.07);border-radius:14px;overflow:hidden}
.card-head{padding:9px 13px;border-bottom:1px solid rgba(255,255,255,.06);display:flex;align-items:center;gap:7px}
.card-label{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.6px;color:rgba(255,255,255,.32);flex:1}
.card-body{padding:12px 13px}
/* Transcription */
.ttext{font-size:13px;line-height:1.75;color:#e2e8f0;min-height:46px;white-space:pre-wrap;word-break:break-word;max-height:180px;overflow-y:auto}
.ttext.muted{color:rgba(255,255,255,.2);font-style:italic}
.live-dot{width:7px;height:7px;background:#22c55e;border-radius:50%;animation:lp 1.5s ease-in-out infinite;flex-shrink:0;display:none}
@keyframes lp{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.75)}}
/* AI */
.aibody{font-size:13px;line-height:1.75;color:#e2e8f0;white-space:pre-wrap;word-break:break-word;min-height:40px;max-height:300px;overflow-y:auto}
.thinking{display:flex;align-items:center;gap:7px;color:rgba(255,255,255,.3);font-size:13px}
.spin{width:13px;height:13px;border:2px solid rgba(99,102,241,.3);border-top-color:#818cf8;border-radius:50%;animation:spin .7s linear infinite;flex-shrink:0}
@keyframes spin{to{transform:rotate(360deg)}}
/* Inputs */
.row{display:flex;gap:8px}
.inp{flex:1;padding:10px 12px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:9px;color:#f1f5f9;font-size:13px;outline:none;transition:.15s;min-width:0}
.inp:focus{border-color:rgba(99,102,241,.5);background:rgba(99,102,241,.04)}
.inp::placeholder{color:rgba(255,255,255,.18)}
.go{padding:9px 15px;background:#6366f1;border:none;border-radius:9px;color:#fff;font-size:13px;font-weight:600;cursor:pointer;transition:.15s;white-space:nowrap;flex-shrink:0}
.go:hover{background:#818cf8}
.go:active{transform:scale(.96)}
.btn{padding:6px 11px;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1);border-radius:8px;color:rgba(255,255,255,.65);font-size:12px;cursor:pointer;transition:.15s;white-space:nowrap}
.btn:hover{background:rgba(255,255,255,.12);color:#fff}
/* Chips */
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{padding:5px 12px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.09);border-radius:20px;font-size:11px;cursor:pointer;transition:.15s;color:rgba(255,255,255,.7)}
.chip:hover{background:rgba(99,102,241,.18);border-color:rgba(99,102,241,.4);color:#e0e7ff}
.chip:active{transform:scale(.95)}
/* Pills */
.mpill{font-size:11px;font-weight:600;padding:3px 8px;background:rgba(99,102,241,.12);border:1px solid rgba(99,102,241,.25);border-radius:7px;color:#818cf8;text-transform:capitalize}
.rpill{font-size:11px;font-weight:600;padding:3px 8px;background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.25);border-radius:7px;color:#f87171;display:none;align-items:center;gap:3px}
.rdot{width:5px;height:5px;background:#ef4444;border-radius:50%;animation:blink 1s infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.2}}
/* Browser mirror */
.browser-top{padding:10px 13px;display:flex;flex-direction:column;gap:8px;border-bottom:1px solid rgba(255,255,255,.05)}
.tab-list{display:flex;flex-direction:column;gap:4px}
.tab-row{display:flex;align-items:center;gap:7px;padding:7px 9px;border-radius:8px;border:1px solid rgba(255,255,255,.07);background:rgba(255,255,255,.03);cursor:pointer;transition:.12s;-webkit-tap-highlight-color:transparent}
.tab-row:hover,.tab-row:active{background:rgba(255,255,255,.07)}
.tab-row.act{border-color:rgba(99,102,241,.35);background:rgba(99,102,241,.08)}
.ticon{width:14px;height:14px;font-size:10px;flex-shrink:0;text-align:center}
.tinfo{flex:1;min-width:0}
.ttitle{font-size:12px;font-weight:500;color:#e2e8f0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.turl{font-size:9px;color:rgba(255,255,255,.28);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px}
.tclose{background:none;border:none;color:rgba(255,255,255,.22);cursor:pointer;padding:2px 6px;border-radius:4px;font-size:15px;line-height:1;-webkit-tap-highlight-color:transparent}
.tclose:hover{color:#f87171}
/* Live mirror */
.mirror-wrap{position:relative;border-radius:9px;overflow:hidden;cursor:crosshair;user-select:none;-webkit-user-select:none;touch-action:none;background:#111;border:1px solid rgba(255,255,255,.07)}
.mirror-wrap img{width:100%;display:block;border-radius:8px;pointer-events:none}
.mirror-placeholder{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:rgba(255,255,255,.18);font-size:12px;font-style:italic}
.mirror-hint{font-size:10px;color:rgba(255,255,255,.2);text-align:center;margin-top:5px}
/* Ripple */
.ripple{position:absolute;width:22px;height:22px;border-radius:50%;border:2px solid rgba(99,102,241,.7);background:rgba(99,102,241,.15);pointer-events:none;transform:translate(-50%,-50%);animation:ripout .4s ease-out forwards}
@keyframes ripout{to{transform:translate(-50%,-50%) scale(2.2);opacity:0}}
/* Key capture area */
.key-row{display:flex;gap:7px;margin-top:9px}
.key-inp{flex:1;padding:8px 11px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.09);border-radius:8px;color:#f1f5f9;font-size:13px;outline:none}
.key-inp:focus{border-color:rgba(99,102,241,.45)}
.key-inp::placeholder{color:rgba(255,255,255,.18)}
/* Misc */
.sbar{font-size:11px;color:rgba(255,255,255,.18);text-align:center;padding:5px;min-height:22px}
.clr{background:none;border:none;color:rgba(255,255,255,.18);cursor:pointer;font-size:11px;padding:2px 5px;border-radius:4px}
.clr:hover{color:rgba(255,255,255,.5)}
/* Auth */
.auth-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.auth-card{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:36px 26px;max-width:320px;width:100%;text-align:center}
.at{font-size:20px;font-weight:700;margin-bottom:6px}
.as{font-size:13px;color:rgba(255,255,255,.32);margin-bottom:26px;line-height:1.55}
.ci{width:156px;padding:13px;text-align:center;letter-spacing:8px;font-size:21px;font-weight:700;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:11px;color:#f1f5f9;outline:none;font-family:monospace;margin-bottom:14px}
.ci:focus{border-color:rgba(99,102,241,.5)}
.ab{width:100%;padding:12px;background:#6366f1;border:none;border-radius:11px;color:#fff;font-size:14px;font-weight:600;cursor:pointer}
.ab:hover{background:#818cf8}
.err{color:#f87171;font-size:12px;margin-top:9px;min-height:17px}
</style>
</head>
<body>

<!-- Auth -->
<div id="authWrap" class="auth-wrap">
  <div class="auth-card">
    <div class="at">thecloser</div>
    <div class="as">Enter the 6-digit access code shown in the overlay settings to connect.</div>
    <br>
    <input id="codeInp" class="ci" type="text" inputmode="numeric" maxlength="6" placeholder="······" autocomplete="off">
    <br>
    <button class="ab" onclick="tryConnect()">Connect</button>
    <div id="authErr" class="err"></div>
  </div>
</div>

<!-- Main -->
<div id="mainWrap" style="display:none">
  <div class="topbar">
    <div class="logo">Mac<span>Overlay</span></div>
    <span id="connBadge" class="badge badge-disc"><span class="badge-dot"></span>Connecting…</span>
  </div>
  <div class="wrap">

    <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px;flex-wrap:wrap">
      <span id="modePill" class="mpill">general</span>
      <span id="recPill" class="rpill"><span class="rdot"></span>Recording</span>
    </div>

    <!-- AI send -->
    <div class="section">
      <div class="row" style="margin-bottom:6px">
        <input id="msgInp" class="inp" type="text" placeholder="Ask the AI (host will review first)…">
        <button class="go" onclick="sendMsg()">Send</button>
      </div>
      <div id="msgStatus" style="font-size:11px;color:rgba(255,200,80,.75);min-height:16px;margin-bottom:6px;padding-left:2px"></div>
      <div id="chips" class="chips"></div>
    </div>

    <!-- Live Transcription -->
    <div class="section card">
      <div class="card-head">
        <span class="live-dot" id="liveDot"></span>
        <span class="card-label">🎙 Live Transcription</span>
        <button class="clr" onclick="doAction('clearTranscription')">Clear</button>
      </div>
      <div class="card-body">
        <div id="transcript" class="ttext muted">Waiting for audio…</div>
      </div>
    </div>

    <!-- AI Response -->
    <div class="section card">
      <div class="card-head">
        <span class="card-label">✨ AI Response</span>
        <button class="clr" onclick="doAction('clearResponse')">Clear</button>
      </div>
      <div class="card-body" id="aiBody">
        <div id="aiResp" class="aibody"></div>
      </div>
    </div>

    <!-- Browser (only when open) -->
    <div class="section card" id="browserCard" style="display:none">
      <div class="card-head">
        <span class="card-label">🌐 Browser</span>
        <div style="display:flex;gap:6px">
          <button class="btn" onclick="doAction('browserNewTab','')">+ Tab</button>
          <button class="btn" onclick="doAction('toggleBrowser')">Close</button>
        </div>
      </div>

      <!-- Tabs + URL bar -->
      <div class="browser-top">
        <div id="tabList" class="tab-list"></div>
        <div class="row">
          <input id="urlInp" class="inp" type="url" placeholder="URL or search…">
          <button class="go" style="padding:9px 12px" onclick="navBrowser()">Go</button>
        </div>
      </div>

      <!-- Live mirror -->
      <div style="padding:10px 13px 8px">
        <div id="mirrorWrap" class="mirror-wrap">
          <img id="mirrorImg" src="" alt="" style="display:none">
          <div id="mirrorPH" class="mirror-placeholder">Loading browser view…</div>
        </div>
        <div class="mirror-hint">Tap to click · Drag to scroll · Type below to input text</div>
        <!-- Keyboard input forwarding -->
        <div class="key-row">
          <input id="keyInp" class="key-inp" type="text" placeholder="Type here to input into browser…" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
          <button class="btn" onclick="sendKey()">↩</button>
        </div>
      </div>
    </div>

    <!-- Browser closed -->
    <div id="browserOffRow" class="section">
      <button class="btn" onclick="doAction('toggleBrowser')">🌐 Open Browser</button>
    </div>

    <div id="sbar" class="sbar"></div>
  </div>
</div>

<script>
var authCode = '';
var evtSrc   = null;
var snapOn   = false;
var snapTm   = null;

// Auto-connect from URL
(function(){
  var p = new URLSearchParams(window.location.search);
  var c = p.get('code');
  if(c && c.length===6){ authCode=c; showMain(); verify(); }
})();

function tryConnect(){
  var c = document.getElementById('codeInp').value.replace(/\s/g,'');
  if(c.length!==6){ setErr('Code must be 6 digits'); return; }
  authCode=c; showMain(); verify();
}
function verify(){
  fetch('/state',{headers:{'X-Access-Code':authCode}})
    .then(function(r){ if(!r.ok) throw new Error('Invalid code'); return r.json(); })
    .then(function(s){ setBadge(true); updateUI(s); startSSE(); })
    .catch(function(e){ showAuth(); setErr(e.message||'Connection failed'); });
}
function showMain(){ document.getElementById('authWrap').style.display='none'; document.getElementById('mainWrap').style.display='block'; }
function showAuth(){ document.getElementById('mainWrap').style.display='none'; document.getElementById('authWrap').style.display='flex'; }
function setErr(m){ document.getElementById('authErr').textContent=m; }
function setBadge(on){
  var b=document.getElementById('connBadge');
  b.className='badge '+(on?'badge-conn':'badge-disc');
  b.innerHTML='<span class="badge-dot"></span>'+(on?'Connected':'Disconnected');
}
function startSSE(){
  if(evtSrc) evtSrc.close();
  evtSrc=new EventSource('/events?code='+encodeURIComponent(authCode));
  evtSrc.onopen=function(){ setBadge(true); };
  evtSrc.onmessage=function(e){ try{ updateUI(JSON.parse(e.data)); }catch(x){} };
  evtSrc.onerror=function(){ setBadge(false); setTimeout(function(){ if(evtSrc)evtSrc.close(); startSSE(); },3000); };
}

var qmap={
  general:['Summarise','Key points','Rephrase','Explain','What to ask?'],
  interview:['Suggest answer','Key points','Rephrase','What to ask?','Summarise'],
  meeting:['Action items','Summarise','What to ask?','Key decisions','Rephrase'],
  call:['Suggest response','Summarise','Rephrase','Follow-ups','Key points']
};
var lastMode='';

function updateUI(s){
  // Transcription
  var t=document.getElementById('transcript'), ld=document.getElementById('liveDot');
  if(s.transcription && s.transcription.trim()){
    t.textContent=s.transcription; t.className='ttext'; t.scrollTop=t.scrollHeight;
  } else { t.textContent='Waiting for audio…'; t.className='ttext muted'; }
  ld.style.display=s.isRecording?'block':'none';

  // AI response
  var ab=document.getElementById('aiBody');
  if(s.isSendingToAI){
    ab.innerHTML='<div class="thinking"><div class="spin"></div>Thinking…</div>';
  } else {
    ab.innerHTML='<div id="aiResp" class="aibody"></div>';
    document.getElementById('aiResp').textContent=s.aiResponse||'';
  }

  document.getElementById('sbar').textContent=s.statusMessage||'';
  document.getElementById('modePill').textContent=s.sessionMode||'general';
  document.getElementById('recPill').style.display=s.isRecording?'flex':'none';
  // Show whether the last sent message is still pending review by the host
  var msgStatus=document.getElementById('msgStatus');
  if(msgStatus) msgStatus.textContent=s.peerMessage?'⏳ Awaiting host review…':'';


  // Chips
  var mode=s.sessionMode||'general';
  if(mode!==lastMode){
    lastMode=mode;
    var acts=(s.quickActions&&s.quickActions.length)?s.quickActions:(qmap[mode]||[]);
    document.getElementById('chips').innerHTML=acts.map(function(a){
      var safe=a.replace(/\\/g,'\\\\').replace(/'/g,"\\'");
      return '<span class="chip" onclick="quickAct(\''+safe+'\')">'+a+'</span>';
    }).join('');
  }

  updateBrowser(s.browser);
}

function updateBrowser(b){
  var card=document.getElementById('browserCard'), off=document.getElementById('browserOffRow');
  if(!b||!b.isOpen){ card.style.display='none'; off.style.display='block'; stopSnap(); return; }
  card.style.display='block'; off.style.display='none'; startSnap();

  var tabs=b.tabs||[], list=document.getElementById('tabList');
  list.innerHTML=tabs.length?tabs.map(function(tab){
    var a=tab.isActive?' act':'', ic=icon(tab.url);
    var id=esc(tab.id), ti=esc(tab.title||tab.url), u=esc(tab.url||'');
    return '<div class="tab-row'+a+'" onclick="doAction(\'browserSwitchTab\',\''+id+'\')"><span class="ticon">'+ic+'</span><div class="tinfo"><div class="ttitle">'+ti+'</div><div class="turl">'+u+'</div></div><button class="tclose" onclick="event.stopPropagation();doAction(\'browserCloseTab\',\''+id+'\')">×</button></div>';
  }).join(''):'<span style="color:rgba(255,255,255,.2);font-size:12px">No tabs</span>';
}

function icon(url){
  if(!url) return '🌐';
  if(url.indexOf('google')>-1)  return '🔍';
  if(url.indexOf('claude')>-1)  return '✨';
  if(url.indexOf('chatgpt')>-1) return '💬';
  if(url.indexOf('github')>-1)  return '🐙';
  if(url.indexOf('youtube')>-1) return '▶';
  return '🌐';
}
function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// ── Snapshot polling ───────────────────────────────────────────────
function startSnap(){ if(!snapOn){ snapOn=true; fetchSnap(); } }
function stopSnap(){ snapOn=false; if(snapTm){clearTimeout(snapTm);snapTm=null;} }

function fetchSnap(){
  if(!snapOn) return;
  var t=new Image();
  t.onload=function(){
    var img=document.getElementById('mirrorImg');
    img.src=t.src; img.style.display='block';
    document.getElementById('mirrorPH').style.display='none';
    if(snapOn) snapTm=setTimeout(fetchSnap,280);
  };
  t.onerror=function(){ if(snapOn) snapTm=setTimeout(fetchSnap,600); };
  t.src='/snapshot?code='+encodeURIComponent(authCode)+'&_t='+Date.now();
}

// ── Mirror interaction ─────────────────────────────────────────────
(function(){
  var wrap=null, dragging=false, dragSx=0, dragSy=0, scrollBuf={dx:0,dy:0,relX:0.5,relY:0.5}, scrollFlush=null;

  document.addEventListener('DOMContentLoaded',function(){
    wrap=document.getElementById('mirrorWrap');
    if(!wrap) return;

    // Mouse click
    wrap.addEventListener('click',function(e){
      if(dragging) return;
      var img=document.getElementById('mirrorImg');
      if(img.style.display==='none') return;
      sendWVClick(e.clientX,e.clientY,wrap);
    });

    // Mouse wheel scroll
    wrap.addEventListener('wheel',function(e){
      e.preventDefault();
      var r=wrap.getBoundingClientRect();
      var rx=(e.clientX-r.left)/r.width, ry=(e.clientY-r.top)/r.height;
      flushScroll(e.deltaX,e.deltaY,rx,ry);
    },{passive:false});

    // Touch: tap = click, drag = scroll
    var touchSx=0,touchSy=0,touchMoved=false;
    wrap.addEventListener('touchstart',function(e){
      touchSx=e.touches[0].clientX; touchSy=e.touches[0].clientY; touchMoved=false;
    },{passive:true});
    wrap.addEventListener('touchmove',function(e){
      e.preventDefault();
      var cx=e.touches[0].clientX, cy=e.touches[0].clientY;
      var dx=touchSx-cx, dy=touchSy-cy;
      if(Math.abs(dx)>4||Math.abs(dy)>4) touchMoved=true;
      var r=wrap.getBoundingClientRect();
      var rx=(cx-r.left)/r.width, ry=(cy-r.top)/r.height;
      flushScroll(dx*1.8,dy*1.8,rx,ry);
      touchSx=cx; touchSy=cy;
    },{passive:false});
    wrap.addEventListener('touchend',function(e){
      if(!touchMoved){
        var t=e.changedTouches[0];
        sendWVClick(t.clientX,t.clientY,wrap);
      }
    },{passive:true});
  });

  function sendWVClick(cx,cy,wrap){
    var r=wrap.getBoundingClientRect();
    var rx=(cx-r.left)/r.width, ry=(cy-r.top)/r.height;
    wvEvent({type:'click',relX:rx,relY:ry});
    // Ripple
    var d=document.createElement('div');
    d.className='ripple';
    d.style.left=(cx-r.left)+'px'; d.style.top=(cy-r.top)+'px';
    wrap.appendChild(d);
    setTimeout(function(){ if(d.parentNode) d.parentNode.removeChild(d); },420);
  }

  function flushScroll(dx,dy,relX,relY){
    scrollBuf.dx+=dx; scrollBuf.dy+=dy;
    if(relX!==undefined) scrollBuf.relX=relX;
    if(relY!==undefined) scrollBuf.relY=relY;
    if(!scrollFlush) scrollFlush=setTimeout(function(){
      if(scrollBuf.dx!==0||scrollBuf.dy!==0){
        wvEvent({type:'scroll',dx:scrollBuf.dx,dy:scrollBuf.dy,relX:scrollBuf.relX,relY:scrollBuf.relY});
        scrollBuf={dx:0,dy:0,relX:scrollBuf.relX,relY:scrollBuf.relY};
      }
      scrollFlush=null;
    },30);
  }
})();

// ── Keyboard input ─────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded',function(){
  var ki=document.getElementById('keyInp');
  if(!ki) return;
  ki.addEventListener('keydown',function(e){
    // Send each keydown event; filter to printable + control keys
    wvEvent({type:'keypress',key:e.key,code:e.code});
    // Don't send Enter twice (sendKey handles it)
    if(e.key==='Enter'){ ki.value=''; }
  });
});

function sendKey(){
  var ki=document.getElementById('keyInp');
  var v=ki.value;
  for(var i=0;i<v.length;i++){
    wvEvent({type:'keypress',key:v[i],code:'Key'+v[i].toUpperCase()});
  }
  ki.value='';
}

// ── Actions ────────────────────────────────────────────────────────
function sendMsg(){
  var i=document.getElementById('msgInp'); var m=i.value.trim();
  if(!m) return; i.value=''; doAction('send',m);
}
function quickAct(l){ doAction('quickAction',l); }
function navBrowser(){
  var i=document.getElementById('urlInp'); var u=i.value.trim();
  if(!u) return; i.value=''; doAction('browserNavigate',u);
}
function wvEvent(obj){
  fetch('/webview-event',{method:'POST',headers:{'Content-Type':'application/json','X-Access-Code':authCode},body:JSON.stringify(obj)});
}
function doAction(type,payload){
  fetch('/action',{method:'POST',headers:{'Content-Type':'application/json','X-Access-Code':authCode},body:JSON.stringify({type:type,payload:payload||''})});
}

// Key bindings
document.addEventListener('DOMContentLoaded',function(){
  document.getElementById('msgInp').addEventListener('keydown',function(e){ if(e.key==='Enter') sendMsg(); });
  document.getElementById('urlInp').addEventListener('keydown',function(e){ if(e.key==='Enter') navBrowser(); });
});
</script>
</body>
</html>
"""#
    }
}
