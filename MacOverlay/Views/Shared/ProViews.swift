import SwiftUI

// TheCloser Pro pieces shared by onboarding, Settings and the interview
// setup screen. See `ProAccount` for how the subscription works.

extension ProAccount.Plan {
    var highlights: [String] {
        switch self {
        case .pro:    return ["No API keys needed", "Top models included",
                              "Transcription built in", "Request new models"]
        case .proMax: return ["Everything in Pro", "The most powerful models",
                              "2.5× the monthly usage"]
        }
    }
}

/// Pro and Pro Max side by side, each with a Subscribe button. Checkout
/// opens in the browser, and this switches over as soon as it's paid.
struct ProPlanPicker: View {
    var body: some View {
        let account = ProAccount.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ProAccount.Plan.allCases) { plan in
                    ProPlanCard(plan: plan, isDisabled: account.isWaitingForCheckout) {
                        Task { await account.subscribe(to: plan) }
                    }
                }
            }
            // Cards as tall as the taller one, not as tall as the window.
            .fixedSize(horizontal: false, vertical: true)

            if account.isWaitingForCheckout {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish checkout in your browser. This updates as soon as it goes through.")
                        .font(.system(size: 11))
                        .foregroundColor(Design.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { account.stopWaitingForCheckout() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Already subscribed on this Mac?")
                        .foregroundColor(Design.Ink.tertiary)
                    Button("Restore") { Task { await account.restore() } }
                        .buttonStyle(.plain)
                        .foregroundColor(Design.Accent.chatGPT)
                }
                .font(.system(size: 11))
            }

            if let problem = account.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(Design.Accent.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One plan: name, price and what it includes. Without `subscribe` it's
/// shown as coming soon.
struct ProPlanCard: View {
    let plan: ProAccount.Plan
    var isDisabled = false
    var subscribe: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(plan.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                if subscribe == nil {
                    Text("Soon")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Design.Surface.controlFill))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(plan.price)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(Design.Ink.primary)
                Text("/month")
                    .font(.system(size: 10))
                    .foregroundColor(Design.Ink.tertiary)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(plan.highlights, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Design.Accent.green)
                        Text(point)
                            .font(.system(size: 10.5))
                            .foregroundColor(Design.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let subscribe {
                Spacer(minLength: 0)
                Button(action: subscribe) {
                    Text("Subscribe")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Design.Ink.inverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Design.Ink.primary))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.45 : 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Design.Surface.raisedFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Design.Surface.hairline, lineWidth: 0.75))
    }
}

/// This month's allowance as a thin bar: "42% used" and when it resets.
/// A percentage rather than dollars, which would show our costs.
struct ProUsageMeter: View {
    let usage: ProAccount.Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(max(usage.usedFraction, 0), 1))
                }
            }
            .frame(height: 5)

            HStack {
                Text("\(usage.percentUsed)% used this month")
                    .foregroundColor(usage.isRunningLow ? color : Design.Ink.secondary)
                Spacer()
                if let periodEnd = usage.periodEndText {
                    Text(periodEnd).foregroundColor(Design.Ink.tertiary)
                }
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }

    private var color: Color {
        if usage.isUsedUp { return Design.Accent.red }
        if usage.isRunningLow { return Design.Accent.amber }
        return Design.Ink.primary
    }
}

/// Above Start on the setup screen once 80% of this month's allowance is
/// used, so it doesn't run out mid-interview unannounced.
struct ProUsageNotice: View {
    var body: some View {
        let account = ProAccount.shared
        if let usage = account.usage, usage.isRunningLow {
            let tint = usage.isUsedUp ? Design.Accent.red : Design.Accent.amber
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: usage.isUsedUp ? "exclamationmark.circle.fill" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11))
                    .foregroundColor(tint)
                Text(usage.isUsedUp
                     ? account.usedUpMessage(usage)
                     : "\(usage.percentUsed)% of this month's \(account.plan?.name ?? "Pro") allowance is used.\(usage.periodEndText.map { " \($0)." } ?? "")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        }
    }
}
