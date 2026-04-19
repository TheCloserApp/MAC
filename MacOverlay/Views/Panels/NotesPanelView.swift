import SwiftUI

struct NotesPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(vm.sessionNotes.isEmpty ? "Session notes"
                                              : "\(vm.sessionNotes.count) note\(vm.sessionNotes.count == 1 ? "" : "s") in this session")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.sessionNotes.isEmpty {
                    Menu {
                        Button("Export Markdown") { vm.exportNotes(asMarkdown: true) }
                        Button("Export Plain Text") { vm.exportNotes(asMarkdown: false) }
                        Divider()
                        Button("Clear", role: .destructive) { vm.clearNotes() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.caption).foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if vm.sessionNotes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No notes yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("AI responses are captured here automatically.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.sessionNotes.reversed()) { note in
                            NoteEntryRow(note: note)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 180)
            }
        }
    }
}

struct NoteEntryRow: View {
    let note: NoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: note.source == .ai ? "sparkles" : "pencil")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(note.mode.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(note.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(note.content)
                .font(.system(size: 11))
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }
}
