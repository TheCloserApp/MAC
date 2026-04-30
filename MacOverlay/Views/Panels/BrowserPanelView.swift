import SwiftUI

struct BrowserPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            splitContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(vm.browserTabs) { tab in
                        BrowserTabItemView(tab: tab)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Button { vm.addTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.05)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("New tab (Google)")
            .padding(.horizontal, 4)

            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 0.5, height: 18)

            HStack(spacing: 2) {
                layoutBtn(1, "rectangle")
                layoutBtn(2, "rectangle.split.2x1")
                layoutBtn(3, "rectangle.split.3x1")
            }
            .padding(.horizontal, 6)
        }
        .background(Color.white.opacity(0.025))
    }

    private func layoutBtn(_ n: Int, _ icon: String) -> some View {
        let active = vm.splitCount == n
        return Button {
            vm.splitCount = n
            while vm.browserTabs.count < n { vm.addTab() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .primary : .secondary.opacity(0.55))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.white.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(n == 1 ? "Single" : "Split \(n)")
    }

    // MARK: Split content

    @ViewBuilder
    private var splitContent: some View {
        @Bindable var vm = vm
        let indices = displayIndices
        if indices.isEmpty {
            Color.clear.frame(height: 0)
        } else if indices.count == 1 {
            BrowserTabContentView(tab: $vm.browserTabs[indices[0]])
                .id(vm.browserTabs[indices[0]].id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ForEach(indices, id: \.self) { idx in
                    BrowserTabContentView(tab: $vm.browserTabs[idx])
                        .id(vm.browserTabs[idx].id)
                        .frame(minWidth: 160, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var displayIndices: [Int] {
        let count = min(vm.splitCount, vm.browserTabs.count)
        guard count > 0 else { return [] }
        let activeIdx = vm.browserTabs.firstIndex(where: { $0.id == vm.activeTabID }) ?? 0
        let start = max(0, min(activeIdx, vm.browserTabs.count - count))
        return Array(start..<(start + count))
    }
}

// MARK: - Tab strip item

struct BrowserTabItemView: View {
    @Environment(OverlayViewModel.self) private var vm
    let tab: BrowserTab

    private var isActive: Bool { vm.activeTabID == tab.id }

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: faviconIcon)
                    .font(.system(size: 9))
                    .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.7))
                Text(tab.title.isEmpty ? (tab.url.host ?? "Tab") : tab.title)
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 100, alignment: .leading)

                Button { vm.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary.opacity(hovering || isActive ? 0.85 : 0))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive ? Color.white.opacity(0.06)
                         : (hovering ? Color.white.opacity(0.03) : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Browser-style underline indicator for the active tab.
            Rectangle()
                .fill(isActive ? Color.accentColor : .clear)
                .frame(height: 1.5)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.activeTabID = tab.id }
        .onHover { hovering = $0 }
        .animation(Design.Motion.fast, value: hovering)
    }

    private var faviconIcon: String {
        let s = tab.url.absoluteString
        if s.contains("claude")  { return "sparkles" }
        if s.contains("chatgpt") { return "bubble.left.fill" }
        if s.contains("google")  { return "magnifyingglass" }
        if s.contains("github")  { return "chevron.left.forwardslash.chevron.right" }
        return "globe"
    }
}

// MARK: - Individual tab content (URL bar + WebView)

struct BrowserTabContentView: View {
    @Binding var tab: BrowserTab
    @State private var urlInput: String
    @StateObject private var webState = WebViewState()

    init(tab: Binding<BrowserTab>) {
        self._tab = tab
        _urlInput = State(initialValue: tab.wrappedValue.url.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebPanelView(url: tab.url, tabID: tab.id, state: webState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tab.url) { _, newURL in
            urlInput = newURL.absoluteString
        }
        .onChange(of: webState.currentURL) { _, newURL in
            if !newURL.isEmpty { urlInput = newURL }
        }
        .onChange(of: webState.title) { _, newTitle in
            if !newTitle.isEmpty { tab.title = newTitle }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { webState.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(webState.canGoBack ? .primary : .primary.opacity(0.22))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!webState.canGoBack)

            Button { webState.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(webState.canGoForward ? .primary : .primary.opacity(0.22))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!webState.canGoForward)

            HStack(spacing: 6) {
                Image(systemName: toolbarIcon)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                TextField("URL", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .onSubmit { navigate() }
                Button { navigate() } label: {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
    }

    private var toolbarIcon: String {
        if urlInput.contains("claude")  { return "sparkles" }
        if urlInput.contains("chatgpt") { return "bubble.left.fill" }
        if urlInput.contains("google")  { return "magnifyingglass" }
        return "globe"
    }

    private func navigate() {
        var raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        if let url = URL(string: raw) { tab.url = url }
    }
}
