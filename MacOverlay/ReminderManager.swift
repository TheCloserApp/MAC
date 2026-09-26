import UserNotifications
import EventKit
import Foundation

class ReminderManager {
    static let shared = ReminderManager()
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func scheduleReminder(for event: EKEvent, minutesBefore: Int, profile: UserProfile) {
        guard let startDate = event.startDate else { return }
        let fireDate = startDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = reminderTitle(event: event, profile: profile)
        content.body  = reminderBody(event: event, minutesBefore: minutesBefore, profile: profile)
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        comps.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "reminder-\(event.eventIdentifier ?? UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    func cancelReminder(for eventIdentifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["reminder-\(eventIdentifier)"])
    }

    func cancelAllReminders() {
        center.removeAllPendingNotificationRequests()
    }

    private func reminderTitle(event: EKEvent, profile: UserProfile) -> String {
        let name = profile.name.isEmpty ? "Hey" : "Hey \(profile.name.components(separatedBy: " ").first ?? profile.name)"
        return "\(name) — upcoming: \(event.title ?? "Event")"
    }

    private func reminderBody(event: EKEvent, minutesBefore: Int, profile: UserProfile) -> String {
        let timeStr = minutesBefore == 15 ? "15 minutes" : "\(minutesBefore) minutes"
        let title   = event.title ?? "your event"

        // Personalise based on keywords in the event title
        let lower = title.lowercased()
        if lower.contains("interview") {
            let role = profile.currentRole.isEmpty ? "the role" : profile.currentRole
            return "\(title) starts in \(timeStr). You're interviewing for \(role) — take a breath, you've got this. Open TheCloser to get real-time coaching."
        } else if lower.contains("standup") || lower.contains("stand-up") || lower.contains("sync") {
            return "\(title) in \(timeStr). Open TheCloser to capture action items and decisions in real time."
        } else if lower.contains("call") || lower.contains("meeting") || lower.contains("review") {
            return "\(title) in \(timeStr). Switch TheCloser to Meeting mode to get summaries and action items."
        } else {
            return "\(title) starts in \(timeStr). TheCloser is ready to assist."
        }
    }
}
