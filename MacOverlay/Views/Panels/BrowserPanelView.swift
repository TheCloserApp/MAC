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
                .padding(.vertical, 5)
            }

            Divider().frame(height: 16)

            Button { vm.addTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New tab (Google)")

            Divider().frame(height: 16)

            HStack(spacing: 1) {
                layoutBtn(1, "rectangle")
                layoutBtn(2, "rectangle.split.2x1")
                layoutBtn(3, "rectangle.split.3x1")
            }
            .padding(.horizontal, 6)
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func layoutBtn(_ n: Int, _ icon: String) -> some View {
        Button {
            vm.splitCount = n
            while vm.browserTabs.count < n { vm.addTab() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(vm.splitCount == n ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, height: 24)
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

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title.isEmpty ? (tab.url.host ?? "Tab") : tab.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .leading)

            Button { vm.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.secondary.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { vm.activeTabID = tab.id }
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
        HStack(spacing: 5) {
            Button { webState.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(webState.canGoBack ? .primary : .primary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!webState.canGoBack)

            Button { webState.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(webState.canGoForward ? .primary : .primary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!webState.canGoForward)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06))
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
