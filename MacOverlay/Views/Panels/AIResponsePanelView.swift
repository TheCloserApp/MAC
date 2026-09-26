import SwiftUI
import AppKit

struct AIResponsePanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Response")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.aiResponse.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.aiResponse, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response")
                }
                Button { vm.aiResponse = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                if vm.isSendingToAI {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.75)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else {
                    MarkdownResponseView(text: vm.aiResponse, baseSize: 12 * vm.textScale,
                                         codeSize: 11 * vm.textScale)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .hiddenScrollGutter()
            .frame(maxHeight: 300)
            .animation(.easeInOut(duration: 0.2), value: vm.isSendingToAI)
        }
    }
}
