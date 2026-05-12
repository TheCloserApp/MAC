import EventKit
import Foundation

@MainActor
class CalendarManager: ObservableObject {
    private let store = EKEventStore()
    @Published var upcomingEvents: [EKEvent] = []
    @Published var isAuthorized = false

    func requestAccess() async -> Bool {
        let granted: Bool
        if #available(macOS 14, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        isAuthorized = granted
        if granted { await refresh() }
        return granted
    }

    func refresh() async {
        guard isAuthorized else { return }
        let now   = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 24, to: now) else { return }
        let pred  = store.predicateForEvents(withStart: now, end: end, calendars: nil)

        let events = await Task.detached(priority: .userInitiated) { [store, pred] in
            store.events(matching: pred)
                .sorted { $0.startDate < $1.startDate }
                .prefix(8)
                .map { $0 }
        }.value

        upcomingEvents = events
    }
}
