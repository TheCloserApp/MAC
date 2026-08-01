import SwiftUI

struct QuickAskPillView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.isQuickAskSending && vm.quickAskResponse.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                    Text("Thinking...")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if !vm.quickAskResponse.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.top, 1)
                    ScrollView {
                        MarkdownResponseView(text: vm.quickAskResponse)
                            .padding(.vertical, 4)
                    }
                    .hiddenScrollGutter()
                    .frame(maxHeight: 260)
                    VStack(spacing: 2) {
                        Button { copyResponse() } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(copied ? Design.Accent.green : Design.Ink.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(copied ? "Copied" : "Copy answer")
                        Button { vm.dismissQuickAsk() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Design.Ink.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Design.Surface.shellFill)
                .opacity(vm.backgroundOpacity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Design.Surface.hairline, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 420)
    }

    /// Copy the answer and flash a checkmark for a moment.
    private func copyResponse() {
        guard vm.copyQuickAskResponse() else { return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
