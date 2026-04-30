import SwiftUI
import EventKit

struct CalendarPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            if vm.calendarAuthorized {
                if vm.calendarEvents.isEmpty {
                    clearState
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(vm.calendarEvents, id: \.eventIdentifier) { event in
                                CalendarEventRow(event: event)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            } else {
                accessGate
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text("Calendar")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(.primary)
            Text(vm.calendarAuthorized ? "Next 24h" : "Off")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            Spacer()
            if !vm.calendarAuthorized {
                Button("Enable") { vm.requestCalendarAccess() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Design.Accent.blue))
                    .buttonStyle(.plain)
            } else {
                Button {
                    Task { await vm.calendarManager.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var clearState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("You're clear")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("No events in the next 24 hours.\nWe'll remind you 15 min before upcoming meetings.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 14)
    }

    private var accessGate: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Calendar access not granted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Grant access to see upcoming events and get reminders before meetings and interviews.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            Button("Enable Calendar") { vm.requestCalendarAccess() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Capsule().fill(Design.Accent.blue))
                .buttonStyle(.plain)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 14)
    }
}

struct CalendarEventRow: View {
    let event: EKEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Calendar color rail.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 2.5, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Event")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(timeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(countdown)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(isImminent ? Design.Accent.amber : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        isImminent
                            ? Design.Accent.amber.opacity(0.14)
                            : Color.white.opacity(0.04)
                    )
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.04) : .clear)
        )
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .animation(Design.Motion.fast, value: hovering)
    }

    private var timeLabel: String {
        guard let start = event.startDate else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(start) ? .none : .short
        return f.string(from: start)
    }

    private var countdown: String {
        guard let start = event.startDate else { return "" }
        let mins = Int(start.timeIntervalSinceNow / 60)
        if mins < 1  { return "now" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    private var isImminent: Bool {
        guard let start = event.startDate else { return false }
        return start.timeIntervalSinceNow < 20 * 60
    }
}
