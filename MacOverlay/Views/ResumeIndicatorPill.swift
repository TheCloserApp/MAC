import SwiftUI

/// Compact hover-expanding chip for one slice of resume state. Multiple
/// pills can sit next to the capsule at once — e.g. "score 72" + "filename"
/// after a match → generate flow. Default state: a small circular icon.
/// On hover: expands rightward with the status text and an X dismiss button.
struct ResumeIndicatorPill: View {
    enum Kind {
        case scoring
        case score(ResumeScore)
        case generating(String)
        case file(URL)
    }

    let kind: Kind
    var onDismiss: (() -> Void)? = nil

    @Environment(OverlayViewModel.self) private var vm
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            mainArea

            if hovering, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .transition(.opacity)
                .help("Dismiss")
            }
        }
        .frame(height: 44)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 22/255, green: 22/255, blue: 24/255))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accent.opacity(0.30), lineWidth: 1)
        )
        .designShadow(Design.Shadow.raised)
        .onHover { isHovering in
            withAnimation(Design.Motion.standard) {
                hovering = isHovering
            }
        }
        .help(staticTooltip)
    }

    /// The icon + status area. For `.file`, the area becomes a real macOS
    /// drag source (NSDraggingSession) so the user can drag the resume to
    /// LinkedIn, Finder, Mail, etc. For other kinds it's a regular button
    /// that opens the resume surface.
    @ViewBuilder
    private var mainArea: some View {
        let visual = HStack(spacing: 6) {
            iconView

            if hovering {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 2)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .contentShape(Rectangle())

        switch kind {
        case .file(let url):
            ZStack {
                FileDragView(fileURL: url)
                visual.allowsHitTesting(false)
            }
            .help("Drag to upload, or click to open")
            .onTapGesture { open() }
        default:
            Button(action: open) { visual }
                .buttonStyle(.plain)
        }
    }

    private func open() {
        vm.primarySurface = .resumes
        vm.isShellMinimized = false
        withAnimation(Design.Motion.spring) {
            vm.isShellExpanded = true
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 36, height: 36)
            Circle()
                .strokeBorder(accent.opacity(0.30), lineWidth: 0.75)
                .frame(width: 36, height: 36)

            switch kind {
            case .scoring, .generating:
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(accent)
            case .score(let s):
                Text("\(s.score)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(accent)
            case .file:
                Image(systemName: "doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
            }
        }
        .frame(width: 44, height: 44)
    }

    // MARK: - Text

    private var statusText: String {
        switch kind {
        case .scoring:
            return "Scoring resume…"
        case .score(let s):
            return "Match score \(s.score)"
        case .generating(let status):
            return status.isEmpty ? "Generating resume…" : status
        case .file(let url):
            return url.lastPathComponent
        }
    }

    private var staticTooltip: String {
        switch kind {
        case .scoring:    return "Scoring resume — click to open"
        case .score:      return "Resume score — click to open"
        case .generating: return "Generating resume — click to open"
        case .file:       return "Generated resume — click to open"
        }
    }

    private var accent: Color {
        switch kind {
        case .scoring, .generating:
            return Design.Accent.amber
        case .score(let s):
            if s.score >= 80 { return Design.Accent.green }
            if s.score >= 60 { return Design.Accent.blue }
            if s.score >= 40 { return Design.Accent.amber }
            return Design.Accent.red
        case .file:
            return Design.Accent.blue
        }
    }
}
