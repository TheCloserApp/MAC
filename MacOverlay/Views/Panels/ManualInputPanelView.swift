import SwiftUI

struct ManualInputPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        HStack(spacing: 8) {
            TextField("Type your message…", text: $vm.manualInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { vm.sendToAI() }
            Button { vm.sendToAI() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundColor(vm.manualInput.isEmpty ? .secondary.opacity(0.3) : .primary)
            }
            .buttonStyle(.plain)
            .disabled(vm.manualInput.isEmpty)
            Button {
                vm.showManualInput = false
                vm.manualInput = ""
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
