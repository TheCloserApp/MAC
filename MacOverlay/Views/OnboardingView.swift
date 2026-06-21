import SwiftUI
import AppKit

/// External docs / signup links surfaced from onboarding. Hoisted to file
/// scope so the force-unwrap is asserted exactly once at app launch — if
/// someone ever breaks the literal, we crash on first reference rather
/// than silently in a SwiftUI subtree.
private let anthropicConsoleKeysURL =
    URL(string: "https://console.anthropic.com/settings/keys")!

/// In-panel onboarding. Lives INSIDE the overlay's NSPanel so it inherits
/// `sharingType = .none` — invisible to screen shares. Three focused steps:
/// welcome → add key → sign in. The sign-in step is the terminal state of
/// the flow: completing it (via Google or guest) finishes onboarding and
/// drops the user into the main shell.
struct OnboardingView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var isPresented: Bool
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable { case welcome, key }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .key:     KeyStep(apiKey: $vm.apiKey, openAI: $vm.openAIApiKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 20, y: 0)),
                removal: .opacity.combined(with: .offset(x: -20, y: 0))
            ))

            footer
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Design.Surface.shellFill)
                .opacity(vm.backgroundOpacity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Design.Surface.hairline, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s == step ? Design.Ink.primary : Design.Ink.muted.opacity(0.45))
                        .frame(width: s == step ? 18 : 5, height: 5)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
                }
            }

            Spacer()

            if step != .welcome {
                Button("Back") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        step = Step(rawValue: step.rawValue - 1) ?? step
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }

            // Advance to the next step, or finish on the last one.
            Button(primaryLabel) {
                if let next = Step(rawValue: step.rawValue + 1) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { step = next }
                } else {
                    finish()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Design.Ink.inverse)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Design.Ink.primary)
            .clipShape(Capsule())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Design.Surface.previewFill)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .key:     return vm.apiKey.isEmpty && vm.openAIApiKey.isEmpty ? "Skip for now" : "Done"
        }
    }

    private func finish() {
        vm.hasCompletedOnboarding = true
        withAnimation(.easeOut(duration: 0.25)) { isPresented = false }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var animateIn = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Design.Surface.raisedFill)
                    .frame(width: 84, height: 84)
                    .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.75))

                WaveformLogo()
                    .frame(width: 44, height: 44)
            }
            .scaleEffect(animateIn ? 1 : 0.8)
            .opacity(animateIn ? 1 : 0)

            VStack(spacing: 6) {
                Text("MacOverlay")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(Design.Ink.primary)
                Text("An AI that listens, thinks, and hides on screen share.")
                    .font(.system(size: 13))
                    .foregroundColor(Design.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 10)
        }
        .padding(24)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.05)) {
                animateIn = true
            }
        }
    }
}

// MARK: - Step 2 · API key

private struct KeyStep: View {
    @Binding var apiKey: String
    @Binding var openAI: String
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your AI key")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                Text("Your key stays on this Mac. One key unlocks every feature.")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Anthropic")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Design.Ink.secondary)
                    Spacer()
                    Link("Get a key →", destination: anthropicConsoleKeysURL)
                        .font(.system(size: 10))
                        .foregroundColor(Design.Accent.chatGPT)
                }
                HStack(spacing: 4) {
                    Group {
                        if visible {
                            TextField("sk-ant-api…", text: $apiKey)
                        } else {
                            SecureField("sk-ant-api…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Design.Ink.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Design.Surface.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(apiKey.isEmpty ? Design.Surface.hairline : Design.Accent.green.opacity(0.45), lineWidth: 1)
                    )

                    Button { visible.toggle() } label: {
                        Image(systemName: visible ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundColor(Design.Ink.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 9))
                Text("Stored locally. Never uploaded anywhere.")
                    .font(.system(size: 10))
            }
            .foregroundColor(Design.Ink.tertiary)

            Spacer()

            // Advanced: OpenAI
            DisclosureGroup {
                HStack(spacing: 4) {
                    SecureField("sk-…", text: $openAI)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Design.Ink.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Design.Surface.inputFill)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .padding(.top, 6)
            } label: {
                Text("Use OpenAI instead")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Reusable kbd key cap

private struct KeyCapView: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Design.Ink.primary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(Design.Surface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Design.Surface.hairline, lineWidth: 0.5)
                    )
            }
        }
    }
}
