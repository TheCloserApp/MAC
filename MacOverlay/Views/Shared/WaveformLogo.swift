import SwiftUI

struct WaveformLogo: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var phases: [CGFloat] = [0, 0.4, 0.8, 0.5, 0.2]

    private let barCount = 5
    private let barWidth: CGFloat = 2.5
    private let spacing:  CGFloat = 2.0
    private let maxH:     CGFloat = 18
    private let minH:     CGFloat = 4
    private let idleHeights: [CGFloat] = [5, 10, 16, 10, 5]

    /// Whether the bars animate. We deliberately keep the logo *static*
    /// during a live interview: the bar stays on screen the whole session
    /// and the `.repeatForever` animation + 0.15s ticker drive continuous
    /// re-renders, which adds avoidable jank exactly when answer latency
    /// matters most. The logo still renders (idle heights) — it just doesn't
    /// animate while the interview is running.
    private var isActive: Bool {
        guard !vm.isInterviewSession else { return false }
        return vm.isRecording || vm.isQuickAsking || vm.isDictating
    }

    private var barColor: Color {
        if vm.isDictating  { return .orange }
        if vm.isQuickAsking { return .red }
        return Color.white
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let h = isActive
                    ? minH + (maxH - minH) * abs(sin(phases[i] * .pi))
                    : idleHeights[i]
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(barColor)
                    .frame(width: barWidth, height: h)
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.4 + Double(i) * 0.07).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.3),
                        value: h
                    )
            }
        }
        .frame(height: maxH)
        .drawingGroup()
        .modifier(WaveformTicker(isActive: isActive, phases: $phases, barCount: barCount))
    }
}

/// Only runs the timer subscription while the waveform is active — avoids
/// publishing every 0.15s forever when collapsed or idle.
private struct WaveformTicker: ViewModifier {
    let isActive: Bool
    @Binding var phases: [CGFloat]
    let barCount: Int

    func body(content: Content) -> some View {
        if isActive {
            content.onReceive(
                Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
            ) { _ in
                for i in 0..<barCount {
                    phases[i] = (phases[i] + CGFloat.random(in: 0.1...0.3))
                        .truncatingRemainder(dividingBy: 2)
                }
            }
        } else {
            content
        }
    }
}
