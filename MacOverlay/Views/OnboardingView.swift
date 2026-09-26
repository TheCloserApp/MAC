import SwiftUI
import AppKit

/// External links surfaced from onboarding. Hoisted to file scope so the
/// force-unwraps are asserted exactly once at app launch — if someone ever
/// breaks a literal, we crash on first reference rather than silently in a
/// SwiftUI subtree.
private let openRouterKeysURL = URL(string: "https://openrouter.ai/keys")!
private let elevenLabsKeysURL = URL(string: "https://elevenlabs.io/app/settings/api-keys")!
/// Tagged as a campaign so interest in Pro shows up in the website's Google
/// Analytics (Acquisition → Traffic acquisition, campaign "pro_interest").
private let proInterestURL = URL(string: "https://www.thecloser.tech/?utm_source=app&utm_medium=onboarding&utm_campaign=pro_interest")!

/// In-panel onboarding. Lives INSIDE the overlay's NSPanel so it inherits
/// `sharingType = .none` — invisible to screen shares.
///
/// welcome → choose → keys (bring your own OpenRouter + ElevenLabs keys)
///                  → plans (we handle everything: subscribe to Pro in Dev
///                           and Beta; coming soon in production, which
///                           falls back to keys)
struct OnboardingView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var isPresented: Bool
    @State private var step: Step = .welcome
    @State private var path: Path?

    enum Step {
        case welcome, choose, keys, plans

        /// Position in the three-dot progress indicator.
        var dot: Int {
            switch self {
            case .welcome:     return 0
            case .choose:      return 1
            case .keys, .plans: return 2
            }
        }
    }

    enum Path { case ownKeys, managed }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .choose:  ChooseStep(path: $path)
                case .keys:    KeyStep(openRouter: $vm.openRouterAPIKey, elevenLabs: $vm.elevenLabsAPIKey)
                case .plans:   PlansStep()
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
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == step.dot ? Design.Ink.primary : Design.Ink.muted.opacity(0.45))
                        .frame(width: i == step.dot ? 18 : 5, height: 5)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
                }
            }

            Spacer()

            if step != .welcome {
                Button("Back") { go(to: previousStep) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }

            Button(primaryLabel) { advance() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Design.Ink.inverse)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Design.Ink.primary)
                .clipShape(Capsule())
                .disabled(step == .choose && path == nil)
                .opacity(step == .choose && path == nil ? 0.45 : 1)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Design.Surface.previewFill)
    }

    private var previousStep: Step {
        switch step {
        case .welcome, .choose: return .welcome
        case .keys, .plans:     return .choose
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .choose:  return "Continue"
        case .keys:    return vm.missingRequiredKeys.isEmpty ? "Done" : "Skip for now"
        case .plans:   return ProAccount.shared.isActive ? "Done" : "Use my own keys"
        }
    }

    private func advance() {
        switch step {
        case .welcome: go(to: .choose)
        case .choose:  go(to: path == .managed ? .plans : .keys)
        case .keys:    finish()
        case .plans:   ProAccount.shared.isActive ? finish() : go(to: .keys)
        }
    }

    private func go(to next: Step) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { step = next }
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
                Text("thecloser")
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

// MARK: - Step 2 · Choose

private struct ChooseStep: View {
    @Binding var path: OnboardingView.Path?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "How do you want to use it?",
                       subtitle: "Pick one to get started.")

            ChoiceCard(icon: "key.fill",
                       title: "Bring your own keys",
                       badge: "Free",
                       detail: "Use your own OpenRouter and ElevenLabs keys. You pay them directly for what you use.",
                       selected: path == .ownKeys) { path = .ownKeys }

            ChoiceCard(icon: "sparkles",
                       title: "We handle everything",
                       badge: FeatureFlags.proSubscriptionsEnabled ? "Pro" : "Coming soon",
                       detail: "No keys, no setup. Top models and transcription, managed for you. From $19/month.",
                       selected: path == .managed) { path = .managed }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

private struct ChoiceCard: View {
    let icon: String
    let title: String
    let badge: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Design.Surface.controlFill))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Design.Ink.primary)
                        Badge(text: badge)
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Design.Ink.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? Design.Accent.green : Design.Ink.muted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Design.Surface.raisedFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Design.Ink.primary.opacity(0.5) : Design.Surface.hairline,
                              lineWidth: selected ? 1 : 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 3a · Keys (bring your own)

private struct KeyStep: View {
    @Binding var openRouter: String
    @Binding var elevenLabs: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Add your keys",
                       subtitle: "Both are needed to start an interview.")

            KeyInput(label: "OpenRouter", hint: "runs every AI model",
                     placeholder: "sk-or-…", link: openRouterKeysURL, text: $openRouter)
            KeyInput(label: "ElevenLabs", hint: "transcribes the interview",
                     placeholder: "sk_…", link: elevenLabsKeysURL, text: $elevenLabs)

            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 9))
                Text("Stored on this Mac. Never uploaded anywhere.")
                    .font(.system(size: 10))
            }
            .foregroundColor(Design.Ink.tertiary)

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

private struct KeyInput: View {
    let label: String
    let hint: String
    let placeholder: String
    let link: URL
    @Binding var text: String
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Design.Ink.secondary)
                Text("· \(hint)")
                    .font(.system(size: 10))
                    .foregroundColor(Design.Ink.tertiary)
                Spacer()
                Link("Get a key →", destination: link)
                    .font(.system(size: 10))
                    .foregroundColor(Design.Accent.chatGPT)
            }
            HStack(spacing: 4) {
                Group {
                    if visible {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
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
                        .stroke(text.isEmpty ? Design.Surface.hairline : Design.Accent.green.opacity(0.45), lineWidth: 1)
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
    }
}

// MARK: - Step 3b · Plans (we handle everything)

private struct PlansStep: View {
    var body: some View {
        let account = ProAccount.shared
        VStack(alignment: .leading, spacing: 12) {
            if let plan = account.plan {
                StepHeader(title: "You're on \(plan.name)",
                           subtitle: "No keys needed. Models and transcription are included, and this Mac is ready for your next interview.")
                ProPlanCard(plan: plan)
                    .fixedSize(horizontal: false, vertical: true)
            } else if FeatureFlags.proSubscriptionsEnabled {
                StepHeader(title: "We handle everything",
                           subtitle: "Pick a plan. Checkout opens in your browser, and the app switches over as soon as it's paid.")
                ProPlanPicker()
            } else {
                StepHeader(title: "We handle everything",
                           subtitle: "Coming soon. Until then, the free version with your own keys has the same interview helper.")

                HStack(alignment: .top, spacing: 10) {
                    ForEach(ProAccount.Plan.allCases) { ProPlanCard(plan: $0) }
                }
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: proInterestURL) {
                    Text("I'm interested. Tell me when it launches →")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Design.Accent.chatGPT)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Design.Ink.primary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Design.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Design.Ink.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Design.Surface.controlFill))
    }
}
