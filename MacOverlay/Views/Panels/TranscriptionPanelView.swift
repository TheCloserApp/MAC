import SwiftUI

struct TranscriptionPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(vm.transcription.isEmpty ? "Listening…" : vm.transcription)
                    .font(.system(size: 12))
                    .foregroundStyle(vm.transcription.isEmpty
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(.primary))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(.easeInOut(duration: 0.15), value: vm.transcription)

                if !vm.transcription.isEmpty {
                    Button { vm.transcription = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, vm.transcription.isEmpty ? 10 : 6)

            if vm.transcription.count > 120 {
                Text("\(vm.transcription.count) chars")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct QuickActionBarView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.sessionMode.quickActions) { action in
                    Button {
                        vm.selectQuickAction(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
