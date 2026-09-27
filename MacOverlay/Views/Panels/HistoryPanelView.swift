import SwiftUI

/// Sessions list (primary surface).
struct HistoryPanelView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var query: String = ""
    /// Which session kind the user is browsing. Three buckets:
    ///   - Interview: sessions started from the Interview tab of the
    ///     Interview surface.
    ///   - Regular call: sessions started from the Regular call tab (and
    ///     legacy `.normal` sessions from before this split existed).
    ///   - Quick Asks: Fn-hold one-shots.
    @State private var segment: Segment = .interview

    enum Segment: Hashable {
        case interview, regularCall, quickAsks

        /// Segments offered in this build. Production shows only Interview.
        static var available: [Segment] {
            var segments: [Segment] = [.interview]
            if FeatureFlags.regularCallEnabled { segments.append(.regularCall) }
            if FeatureFlags.quickAskEnabled    { segments.append(.quickAsks) }
            return segments
        }

        var label: String {
            switch self {
            case .interview:   return "Interview"
            case .regularCall: return "Regular call"
            case .quickAsks:   return "Quick Asks"
            }
        }

        var icon: String {
            switch self {
            case .interview:   return "person.fill.checkmark"
            case .regularCall: return "phone.bubble.fill"
            case .quickAsks:   return "bolt.horizontal.circle"
            }
        }

        var matches: (ChatSession) -> Bool {
            switch self {
            case .interview:   return { $0.kind == .interview }
            // Roll legacy `.normal` (pre-segmentation sessions) into the
            // Regular call bucket so old data still surfaces somewhere.
            case .regularCall: return { $0.kind == .regularCall || $0.kind == .normal }
            case .quickAsks:   return { $0.kind == .quickAsk }
            }
        }
    }

    private var store: SessionStore { vm.sessionStore }

    private var filtered: [ChatSession] {
        let scoped = store.sortedSessions(in: vm.workspaceStore.activeWorkspaceID)
            .filter(segment.matches)
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
            segmentPicker
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
                .hiddenScrollGutter()
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text(segment.label)
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

    /// Three-segment picker for the History surface. Interview / Regular
    /// call / Quick Asks — one segment per ChatSession.Kind bucket so the
    /// flows stay visually separated even though they all live in the
    /// same store.
    private var segmentPicker: some View {
        HStack(spacing: 4) {
            ForEach(Segment.available, id: \.self) { s in
                segmentChip(label: s.label,
                            icon: s.icon,
                            count: count(for: s),
                            isActive: segment == s) {
                    segment = s
                }
            }
            Spacer()
        }
    }

    private func count(for s: Segment) -> Int {
        store.sortedSessions(in: vm.workspaceStore.activeWorkspaceID)
            .filter(s.matches)
            .count
    }

    /// Resume a session and route to the right surface. Interview /
    /// Regular-call sessions land on the Interview surface with their
    /// transcript visible and a "Continue session" affordance at the
    /// end of the messages — clicking that affordance is what flips the
    /// bar into live-call controls. Quick asks open in the standard
    /// chat surface.
    private func openSession(_ s: ChatSession) {
        switch s.kind {
        case .interview:
            vm.interviewSurfaceMode = .interview
            vm.forceInterviewSetup = false
            vm.continueSession(id: s.id, stayInPrimarySurface: true)
            withAnimation(Design.Motion.spring) { vm.primarySurface = .interview }
        case .regularCall, .normal:
            // Legacy `.normal` rolls into Regular call in this UI, so a
            // tap should also land on the Interview surface's Regular
            // call tab rather than dumping the user onto chat.
            vm.interviewSurfaceMode = .regularCall
            vm.forceInterviewSetup = false
            vm.continueSession(id: s.id, stayInPrimarySurface: true)
            withAnimation(Design.Motion.spring) { vm.primarySurface = .interview }
        case .quickAsk:
            vm.continueSession(id: s.id)
        }
    }

    private func segmentChip(label: String,
                             icon: String,
                             count: Int,
                             isActive: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Design.Motion.fast) { action() } }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive ? .primary : .secondary.opacity(0.85))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? .primary : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Color.white.opacity(0.10) : .clear)
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
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
            Image(systemName: segment.icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if query.isEmpty {
                Text(emptyHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            } else {
                Button("Clear search") { query = "" }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No matches" }
        switch segment {
        case .interview:   return "No interviews yet"
        case .regularCall: return "No calls yet"
        case .quickAsks:   return "No quick asks yet"
        }
    }

    private var emptyHint: String {
        switch segment {
        case .interview:
            return "Start one from the Interview tab — it'll land here when you're done."
        case .regularCall:
            return "Pick the Regular call tab on the Interview surface to start a call or chat."
        case .quickAsks:
            return "Hold the Fn key, ask your question, then release — answers land here."
        }
    }

    private func section(label: String, items: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.bottom, 1)

            VStack(spacing: 6) {
                ForEach(items) { s in
                    SessionRow(session: s,
                               isActive: s.id == store.activeSessionID,
                               onOpen:  { openSession(s) },
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                if let preview = previewText {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
                metaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hovering ? 0.9 : 0.5))
                Button(action: onPin) {
                    Image(systemName: session.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(session.isPinned
                                         ? Design.Accent.amber
                                         : .secondary.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(session.isPinned ? "Unpin" : "Pin to top")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive
                      ? Color.accentColor.opacity(0.10)
                      : Color.white.opacity(hovering ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive
                              ? Color.accentColor.opacity(0.45)
                              : Color.white.opacity(hovering ? 0.18 : 0.10),
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Design.Motion.fast, value: hovering)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Design.Accent.amber)
            }
            Text(session.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            modeChip
            countChip
            if session.kind == .quickAsk {
                quickAskChip
            }
            Spacer()
        }
    }

    /// Mode pill (general / interview / coach / etc.) — colored dot + label
    /// in a soft capsule so the row reads as a labeled card rather than a
    /// list item.
    private var modeChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Design.modeColor(session.mode))
                .frame(width: 5, height: 5)
            Text(session.mode.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }

    private var countChip: some View {
        Text(session.summary)
            .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08))
            .clipShape(Capsule())
    }

    /// Quick-ask sessions get a small accent badge so users browsing the
    /// "Sessions" segment can still see at a glance which entries are
    /// one-shots (and vice-versa).
    private var quickAskChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Quick Ask")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(Design.Accent.amber)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Design.Accent.amber.opacity(0.12))
        .clipShape(Capsule())
    }

    private var previewText: String? {
        guard let last = session.turns.last else { return nil }
        let trimmed = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
