import SwiftUI
import EventKit

struct CalendarPanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Upcoming events")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.calendarAuthorized {
                    Button("Enable Calendar") { vm.requestCalendarAccess() }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                } else {
                    Button {
                        Task { await vm.calendarManager.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if vm.calendarAuthorized {
                if vm.calendarEvents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No events in the next 24 hours")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("You're clear. We'll remind you 15 min before upcoming events.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                } else {
                    ForEach(vm.calendarEvents, id: \.eventIdentifier) { event in
                        CalendarEventRow(event: event)
                    }
                    .padding(.bottom, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Calendar access not granted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Grant access to see upcoming events and get reminders before meetings and interviews.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Enable Calendar") { vm.requestCalendarAccess() }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
            }
        }
    }
}

struct CalendarEventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Event")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(timeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(countdown)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isImminent ? .orange : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
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
