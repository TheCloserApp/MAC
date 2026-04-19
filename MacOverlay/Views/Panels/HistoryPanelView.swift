import SwiftUI

/// Sessions list (primary surface). Click a row to continue that session —
/// the shell jumps back to the chat view automatically. Grouped by age so
/// long lists stay scannable.
struct HistoryPanelView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var query: String = ""

    private var store: SessionStore { vm.sessionStore }

    private var filtered: [ChatSession] {
        let scoped = store.sortedSessions(in: vm.workspaceStore.activeWorkspaceID)
        guard !query.isEmpty else { return scoped }
        let q = query.lowercased()
        return scoped.filter { s in
            s.displayTitle.lowercased().contains(q)
                || s.turns.contains { $0.content.lowercased().contains(q) }
        }
    }

    /// Buckets sessions into Today / Yesterday / Past week / Older.
    private var grouped: [(label: String, items: [ChatSession])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [ChatSession])] = [
            ("Today", []),
            ("Yesterday", []),
            ("Past 7 days", []),
            ("Older", []),
        ]
        for s in filtered {
            let d = s.updatedAt
            if cal.isDateInToday(d) {
                buckets[0].1.append(s)
            } else if cal.isDateInYesterday(d) {
                buckets[1].1.append(s)
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), d > weekAgo {
                buckets[2].1.append(s)
            } else {
                buckets[3].1.append(s)
            }
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        ForEach(grouped, id: \.label) { group in
                            section(label: group.label, items: group.items)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("Search sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No sessions yet" : "No matches")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if query.isEmpty {
                Text("Every chat is saved here automatically.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Button("Clear search") { query = "" }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func section(label: String, items: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.horizontal, 8)

            VStack(spacing: 2) {
                ForEach(items) { s in
                    row(s)
                }
            }
        }
    }

    private func row(_ s: ChatSession) -> some View {
        SessionRow(session: s,
                   isActive: s.id == store.activeSessionID,
                   onOpen: { vm.continueSession(id: s.id) },
                   onDelete: { vm.sessionStore.delete(id: s.id) })
    }

    private func previewText(for session: ChatSession) -> String? {
        guard let last = session.turns.last else { return nil }
        let trimmed = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ChatSession
    let isActive: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.md) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : (hovering ? .secondary.opacity(0.3) : .clear))
                .frame(width: 2)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if isActive {
                        Text("OPEN")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let preview = previewText {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Design.modeColor(session.mode))
                            .frame(width: 5, height: 5)
                        Text(session.mode.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text("·").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                    Text(session.summary)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 0.3 : (hovering ? 1 : 0.5))
            .animation(Design.Motion.fast, value: hovering)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.accentColor.opacity(0.08)
                     : (hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Design.Motion.fast, value: hovering)
    }

    private var previewText: String? {
        guard let last = session.turns.last else { return nil }
        let trimmed = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
