import SwiftUI

/// Sheet shown when a free user tries to do something gated (right now: a
/// résumé generation past their weekly quota). Surfaces the current usage,
/// the time until the next slot opens, and an Upgrade button.
///
/// The Upgrade button currently flips the local flag — there's no payments
/// integration yet. When StoreKit / a backend is added, that's the only
/// call site that needs to change (route through a SubscriptionService).
struct PaywallSheet: View {
    @Environment(OverlayViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to Premium")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Unlimited résumé generations and priority features.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            usageRow
            Divider()
            comparison

            Spacer(minLength: 0)

            HStack {
                Button("Maybe later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    // Local-only upgrade. Real billing would go through
                    // StoreKit (Mac App Store) or a backend (Stripe etc.).
                    vm.entitlement.upgradeToPremium()
                    dismiss()
                } label: {
                    Label("Upgrade to Premium", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
    }

    private var usageRow: some View {
        let used    = vm.quota.generationsInWindow()
        let total   = EntitlementStore.freeResumesPerWeek
        let pct     = min(1.0, Double(used) / Double(max(1, total)))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This week")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(used) / \(total) used")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(used >= total ? .orange : .secondary)
            }
            ProgressView(value: pct)
                .tint(used >= total ? .orange : .accentColor)
            if let reset = vm.quota.nextResetDate() {
                Text("Next slot opens \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Resets on a rolling 7-day window.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var comparison: some View {
        HStack(alignment: .top, spacing: 18) {
            tierColumn(
                title: "Free",
                badge: nil,
                features: [
                    "\(EntitlementStore.freeResumesPerWeek) résumés / 7 days",
                    "All AI models you bring keys for",
                    "Local-only data",
                ]
            )
            Divider().frame(height: 110)
            tierColumn(
                title: "Premium",
                badge: "RECOMMENDED",
                features: [
                    "Unlimited résumé generations",
                    "All AI models you bring keys for",
                    "Local-only data",
                    "Priority support",
                ]
            )
        }
    }

    private func tierColumn(title: String, badge: String?, features: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            ForEach(features, id: \.self) { f in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                    Text(f)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
