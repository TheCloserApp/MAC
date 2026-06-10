import SwiftUI

/// Central design tokens. Use these instead of magic numbers. Keeps the app
/// cohesive and makes global restyles a one-file change.
enum Design {
    // MARK: - Spacing (4pt grid)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 6
        static let md:  CGFloat = 10
        static let lg:  CGFloat = 14
        static let xl:  CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - Corner radius
    enum Radius {
        static let sm: CGFloat = 5
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: - Typography
    enum Font {
        /// Compact metadata (timestamps, counts, chips)
        static let micro  = SwiftUI.Font.system(size: 9,  weight: .medium)
        static let tiny   = SwiftUI.Font.system(size: 10, weight: .medium)
        /// Secondary UI (hints, labels)
        static let small  = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Primary body text
        static let body   = SwiftUI.Font.system(size: 12, weight: .regular)
        /// Section headings / emphasised body
        static let bodyBold = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Titles
        static let title    = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let largeTitle = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let hero    = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// Uppercase "eyebrow" section labels
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .semibold)
    }

    // MARK: - Surface fills (the dark "glass" base under every shell capsule
    // and card). Defined here so a global tone tweak is a one-line change
    // instead of a repo-wide search-and-replace.
    enum Surface {
        /// Base fill under shell capsules, cards, panels, and onboarding.
        /// Slightly warmer than pure neutral grey so it reads as a tinted
        /// dark surface rather than chrome.
        static let shellFill = Color(red: 22/255, green: 22/255, blue: 24/255)
    }

    // MARK: - macOS system accents (used by sidebar / top strip / chat rail)
    enum Accent {
        static let blue   = Color(red: 10/255,  green: 132/255, blue: 255/255)
        static let green  = Color(red: 52/255,  green: 199/255, blue: 89/255)
        static let red    = Color(red: 255/255, green: 69/255,  blue: 58/255)
        static let amber  = Color(red: 255/255, green: 159/255, blue: 10/255)
        static let pink   = Color(red: 255/255, green: 55/255,  blue: 95/255)
        static let purple = Color(red: 191/255, green: 90/255,  blue: 242/255)
        static let teal   = Color(red: 100/255, green: 210/255, blue: 255/255)
    }

    // MARK: - Animation curves
    enum Motion {
        /// Quick feedback (press, reveal)
        static let fast     = Animation.easeInOut(duration: 0.16)
        /// Standard UI transitions
        static let standard = Animation.easeInOut(duration: 0.22)
        /// Bouncier state changes (tabs, modes)
        static let spring   = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// Punchier spring for accents
        static let pop      = Animation.spring(response: 0.28, dampingFraction: 0.75)
        /// Smooth ease-out for large reveals (pill → composer expansion).
        /// MUST use the exact same bezier as the NSPanel's
        /// `CAMediaTimingFunction(name: .easeOut)` — which is the Apple
        /// curve `(0.0, 0.0, 0.58, 1.0)` — otherwise the SwiftUI content
        /// and the AppKit panel edge animate at slightly different rates
        /// and the bar contents visibly drift / "jump" mid-resize.
        /// `Animation.easeOut` does NOT necessarily use that curve, so
        /// the explicit `timingCurve` form is what guarantees lockstep.
        static let expand   = Animation.timingCurve(0.0, 0.0, 0.58, 1.0, duration: 0.32)
    }

    // MARK: - Shadow
    enum Shadow {
        static let card   = ShadowStyle(color: .black.opacity(0.08),  radius: 4,  y: 1)
        static let raised = ShadowStyle(color: .black.opacity(0.12),  radius: 8,  y: 2)
        static let modal  = ShadowStyle(color: .black.opacity(0.20),  radius: 18, y: 6)
    }

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    /// Gap between floating glass cards / cells.
    static let cardGap: CGFloat = 14

    // MARK: - Semantic colors for the 4 session modes
    static func modeColor(_ mode: SessionMode) -> Color {
        switch mode {
        case .general:   return .purple
        case .interview: return .green
        case .meeting:   return .blue
        case .call:      return .orange
        }
    }
}

extension View {
    func designShadow(_ style: Design.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: 0, y: style.y)
    }

    /// Frosted-glass card treatment: translucent material + rounded corners +
    /// hairline border + subtle shadow. Use this for every floating element
    /// in the overlay shell so they look like distinct, hovering glass panels.
    func glassCard(cornerRadius: CGFloat = Design.Radius.lg,
                   opacity: Double = 1.0,
                   shadow: Design.ShadowStyle = Design.Shadow.raised) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Design.Surface.shellFill)
                    .opacity(opacity)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .designShadow(shadow)
    }

    /// Card with separate top and bottom corner radii — used for stacked
    /// cards that meet flush with sharp inner corners and rounded outer
    /// corners. Same dark surface + hairline border + raised shadow as
    /// `glassCard()`.
    func cardSurface(topRadius: CGFloat,
                     bottomRadius: CGFloat,
                     opacity: Double = 1.0,
                     shadow: Design.ShadowStyle = Design.Shadow.raised) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        return self
            .background { shape.fill(Design.Surface.shellFill).opacity(opacity) }
            .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75) }
            .clipShape(shape)
            .designShadow(shadow)
    }
}

/// Hover-responsive scale + opacity for interactive buttons.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.02 : 1.0)
            .brightness(hovering ? 0.02 : 0)
            .animation(Design.Motion.fast, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Subtle hover lift for primary buttons.
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// Background that reveals on hover — for list rows.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var color: Color = .primary.opacity(0.06)
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.md)
                    .fill(hovering ? color : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(_ color: Color = .primary.opacity(0.06)) -> some View {
        modifier(HoverHighlight(color: color))
    }
}

/// Three-dot typing indicator used for streaming / thinking states. Uses
/// TimelineView so the animation is driven purely by the frame clock — no
/// Timer to leak, no @State to maintain, pauses automatically when off-screen.
struct TypingIndicatorView: View {
    /// Total cycle duration. 1.2s feels natural — not too fast, not sluggish.
    private let cycle: Double = 1.2
    /// Stagger between dots (in fraction of cycle).
    private let stagger: Double = 0.14

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(dotOpacity(time: t, index: i))
                        .scaleEffect(dotScale(time: t, index: i))
                }
            }
        }
    }

    /// 0.3 → 1.0 sine pulse, delayed per dot.
    private func dotOpacity(time: Double, index: Int) -> Double {
        let phase = phase(time: time, index: index)
        return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * 2 * .pi))
    }

    /// 0.85 → 1.15 gentle scale pulse.
    private func dotScale(time: Double, index: Int) -> Double {
        let phase = phase(time: time, index: index)
        return 0.88 + 0.22 * (0.5 + 0.5 * sin(phase * 2 * .pi))
    }

    private func phase(time: Double, index: Int) -> Double {
        let shifted = time - Double(index) * stagger
        return (shifted.truncatingRemainder(dividingBy: cycle)) / cycle
    }
}
