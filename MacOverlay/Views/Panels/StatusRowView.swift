import SwiftUI

struct StatusRowView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        let isError = vm.statusMessage.hasPrefix("Error")
            || vm.statusMessage.hasPrefix("Screen Recording")
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundColor(isError ? .orange : .secondary)
            Text(vm.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(isError ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { vm.statusMessage = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
