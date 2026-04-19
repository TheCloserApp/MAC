import SwiftUI

struct PeerMessagePanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.purple.opacity(0.8))
                Text("Peer wants to ask:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.purple.opacity(0.8))
                Spacer()
                Button { vm.peerMessage = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(vm.peerMessage)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                Button {
                    vm.sendPeerMessageToAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                        Text("Send to AI")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.75))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.15), value: vm.peerMessage)
    }
}
