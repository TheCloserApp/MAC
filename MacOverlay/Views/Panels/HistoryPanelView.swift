import SwiftUI

/// Sessions list (primary surface).
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

    private var grouped: [(label: String, items: [ChatSession])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [ChatSession])] = [
            ("Pinned", []), ("Today", []), ("Yesterday", []),
            ("Past 7 days", []), ("Older", []),
        ]
        for s in filtered {
            if s.isPinned { buckets[0].1.append(s); continue }
            let d = s.updatedAt
            if cal.isDateInToday(d) { buckets[1].1.append(s) }
            else if cal.isDateInYesterday(d) { buckets[2].1.append(s) }
            else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), d > weekAgo {
                buckets[3].1.append(s)
            } else { buckets[4].1.append(s) }
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.label) { group in
                            section(label: group.label, items: group.items)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(.primary)
            Text("\(filtered.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
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
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No sessions yet" : "No matches")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if query.isEmpty {
                Text("Every chat is saved here automatically.")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Button("Clear search") { query = "" }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func section(label: String, items: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.bottom, 1)

            VStack(spacing: 1) {
                ForEach(items) { s in
                    SessionRow(session: s,
                               isActive: s.id == store.activeSessionID,
                               onOpen:  { vm.continueSession(id: s.id) },
                               onPin:   { vm.sessionStore.togglePin(id: s.id) },
                               onDelete: { vm.sessionStore.delete(id: s.id) })
                }
            }
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: ChatSession
    let isActive: Bool
    let onOpen: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Leading active rail.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isActive ? Color.accentColor : .clear)
                .frame(width: 2.5, height: 22)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Design.Accent.amber)
                    }
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let preview = previewText {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Design.modeColor(session.mode))
                            .frame(width: 5, height: 5)
                        Text(session.mode.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(session.summary)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button(action: onPin) {
                    Image(systemName: session.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(session.isPinned ? Design.Accent.amber : .secondary.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(session.isPinned ? "Unpin" : "Pin session to top")
                .opacity(session.isPinned ? 1 : (hovering ? 1 : 0))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .opacity(isActive ? 0.3 : (hovering ? 1 : 0))
            }
            .animation(Design.Motion.fast, value: hovering)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous)
                .fill(isActive
                      ? Color.accentColor.opacity(0.08)
                      : (hovering ? Color.white.opacity(0.04) : .clear))
        )
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
