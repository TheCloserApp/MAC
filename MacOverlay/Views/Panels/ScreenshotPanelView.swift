import SwiftUI

struct ScreenshotPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 8) {
            if let img = vm.pendingScreenshot {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(height: 36).cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
            Text("Screenshot attached").font(.caption2).foregroundColor(.secondary)
            Spacer()
            Button { vm.pendingScreenshot = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
