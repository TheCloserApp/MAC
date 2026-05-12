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

    enum Step: Int, CaseIterable { case welcome, key, signIn }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .key:     KeyStep(apiKey: $vm.apiKey, openAI: $vm.openAIApiKey)
                case .signIn:  SignInStep(onContinue: finish)
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
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(8)
        // When the user authenticates from inside the sign-in step (Google
        // OAuth round-trip or "Continue as guest"), automatically close
        // onboarding instead of forcing them to click a redundant "Done"
        // button on the page they just signed in from.
        .onChange(of: vm.auth.isSignedIn) { wasSignedIn, isSignedIn in
            if !wasSignedIn && isSignedIn && step == .signIn { finish() }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.25))
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
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }

            // The sign-in step is the terminal state — its own buttons
            // (Google, Continue as guest) are what completes onboarding,
            // so we don't render a redundant "Continue" pill in the footer.
            if step != .signIn {
                Button(primaryLabel) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        step = Step(rawValue: step.rawValue + 1) ?? step
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.04))
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .key:     return vm.apiKey.isEmpty && vm.openAIApiKey.isEmpty ? "Skip for now" : "Continue"
        case .signIn:  return ""
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
                    .fill(
                        .linearGradient(colors: [Color.accentColor.opacity(0.3), Color.purple.opacity(0.2)],
                                        startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 84, height: 84)
                    .blur(radius: 12)

                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(
                        .linearGradient(colors: [.accentColor, .purple],
                                        startPoint: .top, endPoint: .bottom)
                    )
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .scaleEffect(animateIn ? 1 : 0.8)
            .opacity(animateIn ? 1 : 0)

            VStack(spacing: 6) {
                Text("MacOverlay")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("An AI that listens, thinks, and hides on screen share.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
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
                Text("Your key stays on this Mac. One key unlocks every feature.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Anthropic")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Link("Get a key →", destination: anthropicConsoleKeysURL)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(apiKey.isEmpty ? Color.clear : Color.green.opacity(0.4), lineWidth: 1)
                    )

                    Button { visible.toggle() } label: {
                        Image(systemName: visible ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
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
            .foregroundColor(.secondary.opacity(0.8))

            Spacer()

            // Advanced: OpenAI
            DisclosureGroup {
                HStack(spacing: 4) {
                    SecureField("sk-…", text: $openAI)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .padding(.top, 6)
            } label: {
                Text("Use OpenAI instead")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Step 3 · Sign in

/// Final onboarding step. We end on sign-in (rather than a generic "you're
/// ready" screen) because authentication is the gate to per-user features
/// (résumés, sessions, prompt sync) — finishing the tour without a way to
/// identify the user just defers the prompt to a popup later.
private struct SignInStep: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var animateIn = false
    /// Called when the user finishes the sign-in step *without* a fresh
    /// auth round-trip — i.e. they were already signed in (replaying the
    /// welcome tour from Settings) and just want to dismiss it.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        .linearGradient(colors: [Color.accentColor.opacity(0.30), Color.purple.opacity(0.20)],
                                        startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 72, height: 72)
                    .blur(radius: 10)

                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(
                        .linearGradient(colors: [.accentColor, .purple],
                                        startPoint: .top, endPoint: .bottom)
                    )
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(animateIn ? 1 : 0.85)
            .opacity(animateIn ? 1 : 0)

            if vm.auth.isSignedIn {
                signedInContent
            } else {
                signInContent
            }

            HStack(spacing: 4) {
                Text("Then summon the overlay anywhere with")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
                KeyCapView(keys: ["⌃", "⌥", "␣"])
            }
        }
        .padding(20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                animateIn = true
            }
        }
    }

    /// Default content — the user hasn't signed in yet. Drives the OAuth
    /// or guest flow. The parent's `onChange(of: isSignedIn)` finishes
    /// onboarding once auth lands, so neither button needs to call
    /// `onContinue` directly.
    private var signInContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Sign in to save your work")
                    .font(.system(size: 18, weight: .semibold))
                Text("Your résumés, sessions, and saved prompts stay tied to your account. Or continue as a guest — your data lives on this Mac only.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 8)

            VStack(spacing: 8) {
                GoogleSignInButton {
                    vm.auth.signInWithGoogle()
                }
                .frame(width: 220, height: 36)
                .disabled(vm.auth.isAuthenticating || !GoogleClientID.isConfigured)

                if !GoogleClientID.isConfigured {
                    Text("Google sign-in not configured — paste your client ID into GoogleClientID.swift to enable.")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                Button("Continue as guest") {
                    vm.auth.continueAsGuest()
                    vm.bindUserScopedStores()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)

                if vm.auth.isAuthenticating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser…")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                if let err = vm.auth.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    /// Replay-the-tour case: the user is already authenticated, so the
    /// sign-in form would be redundant. Show a recap with a single
    /// "Continue" button that just dismisses onboarding.
    private var signedInContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text("You're all set")
                    .font(.system(size: 18, weight: .semibold))
                if let name = vm.auth.currentUser?.displayName {
                    Text("Signed in as \(name).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 8)

            Button(action: onContinue) {
                Text("Start Using MacOverlay")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
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
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }
}
