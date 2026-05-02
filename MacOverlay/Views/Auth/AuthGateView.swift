import SwiftUI

/// Wraps the overlay's content. Renders the sign-in screen when there's no
/// authenticated user, otherwise passes through to `content`.
///
/// Sign-in options:
/// - Google (primary) — OAuth 2.0 with PKCE via the system browser. No
///   Apple Developer account required, no SDK, works against an ad-hoc
///   signed bundle.
/// - Continue as guest — escape hatch for users who don't want to sign in.
///   Backs the user with a stable per-install UUID so their quota persists.
struct AuthGateView<Content: View>: View {
    @Environment(OverlayViewModel.self) private var vm
    @ViewBuilder var content: () -> Content

    var body: some View {
        if vm.auth.isSignedIn {
            content()
        } else {
            SignInScreen()
        }
    }
}

private struct SignInScreen: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            // Solid dark glass surface so the sign-in screen is readable
            // against any desktop background. Without this, the panel's
            // .clear backgroundColor lets the desktop bleed through.
            .glassCard(cornerRadius: 18)
            .onAppear {
                // The collapsed-pill panel size (96pt tall) is too small to
                // show the sign-in screen. Force the panel to expand so
                // there's room to render the form.
                if !vm.isShellExpanded { vm.isShellExpanded = true }
            }
    }

    private var content: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)

            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Welcome to Mac Overlay")
                    .font(.system(size: 16, weight: .semibold))
                Text("Sign in to save your résumés and unlock the full app.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                GoogleSignInButton {
                    vm.auth.signInWithGoogle()
                }
                .frame(width: 240, height: 36)
                .disabled(vm.auth.isAuthenticating || !GoogleClientID.isConfigured)

                if !GoogleClientID.isConfigured {
                    Text("Google sign-in not configured. Paste your client ID into GoogleClientID.swift to enable.")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
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
                        .padding(.horizontal, 12)
                }
            }

            Text("Free plan: \(EntitlementStore.freeResumesPerWeek) résumés / 7 days. Upgrade anytime.")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.6))

            Spacer(minLength: 4)
        }
        .onChange(of: vm.auth.currentUser) { _, _ in
            vm.bindUserScopedStores()
        }
    }
}

/// Google's branded sign-in button. Spec: white background, 1pt border,
/// 4-color "G" logo on the left, "Sign in with Google" text in Roboto.
/// We approximate Roboto with `.system(.medium)` since the system font
/// looks fine and dragging Roboto into the bundle is overkill.
///
/// See https://developers.google.com/identity/branding-guidelines for
/// the official spec — important if you ever publish to a Google Workspace
/// Marketplace listing or pass Google's brand review.
private struct GoogleSignInButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                GoogleGLogo()
                    .frame(width: 18, height: 18)
                Text("Sign in with Google")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 0.24, green: 0.24, blue: 0.24))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(hovering ? 0.95 : 1.0))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(red: 0.85, green: 0.85, blue: 0.85), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The familiar 4-color "G" mark drawn in SwiftUI so we don't have to
/// bundle a PNG. Not pixel-perfect against Google's SVG but close enough
/// to read as the Google logo.
private struct GoogleGLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let strokeW = r * 0.42

            // Four arcs in Google's brand colors. Angles are in degrees,
            // 0° = 3 o'clock, increasing clockwise.
            let segments: [(start: Double, end: Double, color: Color)] = [
                (-30, 90, Color(red: 0.26, green: 0.52, blue: 0.96)),  // blue   — bottom-right
                (90, 195, Color(red: 0.20, green: 0.66, blue: 0.33)),  // green  — bottom-left
                (195, 285, Color(red: 0.98, green: 0.74, blue: 0.02)), // yellow — top-left
                (285, 330, Color(red: 0.92, green: 0.26, blue: 0.21)), // red    — top-right
            ]

            for seg in segments {
                let path = Path { p in
                    p.addArc(center: center,
                             radius: r - strokeW / 2,
                             startAngle: .degrees(seg.start),
                             endAngle:   .degrees(seg.end),
                             clockwise: false)
                }
                ctx.stroke(path, with: .color(seg.color),
                           style: StrokeStyle(lineWidth: strokeW, lineCap: .butt))
            }

            // The horizontal bar of the "G" — a small blue rectangle on the
            // right side that connects the inner edge to the outer edge.
            let bar = CGRect(
                x: center.x,
                y: center.y - strokeW * 0.28,
                width: r,
                height: strokeW * 0.56
            )
            ctx.fill(Path(bar), with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }
    }
}
