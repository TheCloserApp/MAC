import SwiftUI
import AppKit

/// Unified bottom input. Recording start/stop lives in the top strip
/// (mode-aware), so this bar focuses on the text/screenshot/send path.
struct InputBarView: View {
    @Environment(OverlayViewModel.self) private var vm
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            if vm.pendingScreenshot != nil {
                screenshotChip.padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(spacing: 8) {
                screenshotButton

                TextField("Ask the AI anything…", text: $vm.manualInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                if !vm.manualInput.isEmpty {
                    Button { vm.manualInput = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                inputFocused = true
            }
        }
    }

    // MARK: - Components

    private var screenshotButton: some View {
        Button {
            NotificationCenter.default.post(name: .captureScreenshot, object: nil)
        } label: {
            Image(systemName: vm.pendingScreenshot != nil ? "camera.fill" : "camera")
                .font(.system(size: 14))
                .foregroundColor(vm.pendingScreenshot != nil ? .accentColor : .secondary.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.secondary.opacity(vm.pendingScreenshot != nil ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .help("Capture screen (⌃⌥S)")
    }

    private var sendButton: some View {
        let enabled = vm.canSend || !vm.manualInput.isEmpty
        return Button { send() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(enabled ? Color.accentColor : Color.secondary.opacity(0.15))
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(enabled ? .white : .secondary.opacity(0.6))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send (⏎)")
    }

    @ViewBuilder
    private var screenshotChip: some View {
        if let img = vm.pendingScreenshot {
            HStack(spacing: 6) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("Screenshot attached")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button { vm.pendingScreenshot = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func send() {
        if !vm.manualInput.isEmpty { vm.showManualInput = true }
        vm.sendToAI()
    }
}
