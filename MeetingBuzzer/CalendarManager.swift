import EventKit
import Foundation

class CalendarManager {
    let eventStore = EKEventStore()

    private let enabledIDsKey = "EnabledCalendarIdentifiers"

    /// nil = user hasn't customized, all calendars enabled.
    /// Non-nil = explicit set of enabled calendar identifiers.
    var enabledCalendarIDs: Set<String>? {
        get {
            guard let arr = UserDefaults.standard.array(forKey: enabledIDsKey) as? [String] else { return nil }
            return Set(arr)
        }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(Array(newValue), forKey: enabledIDsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enabledIDsKey)
            }
        }
    }

    func allCalendars() -> [EKCalendar] {
        return eventStore.calendars(for: .event).sorted { a, b in
            if a.source.title != b.source.title { return a.source.title < b.source.title }
            return a.title < b.title
        }
    }

    func isEnabled(_ calendar: EKCalendar) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }
        return enabled.contains(calendar.calendarIdentifier)
    }

    func setEnabled(_ calendar: EKCalendar, enabled: Bool) {
        var ids = enabledCalendarIDs ?? Set(allCalendars().map { $0.calendarIdentifier })
        if enabled { ids.insert(calendar.calendarIdentifier) }
        else { ids.remove(calendar.calendarIdentifier) }
        enabledCalendarIDs = ids
    }

    func enableAllCalendars() {
        enabledCalendarIDs = nil
    }

    func enabledCalendars() -> [EKCalendar] {
        return allCalendars().filter { isEnabled($0) }
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                if let error = error {
                    print("Calendar access error: \(error.localizedDescription)")
                }
                completion(granted)
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                if let error = error {
                    print("Calendar access error: \(error.localizedDescription)")
                }
                completion(granted)
            }
        }
    }

    /// Returns the next event starting within the next 2 hours.
    /// Includes events from enabled calendars, plus events where the user is
    /// the organizer or an attendee (even if that event's calendar is disabled).
    func nextUpcomingEvent() -> EKEvent? {
        let now = Date()
        let twoHoursFromNow = now.addingTimeInterval(2 * 60 * 60)

        // Query all calendars, then filter in code so attendee-only events still match
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-30),
            end: twoHoursFromNow,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.startDate.timeIntervalSince(now) > -300 }
            .filter { event in
                if isEnabled(event.calendar) { return true }
                if event.organizer?.isCurrentUser == true { return true }
                if let attendees = event.attendees,
                   attendees.contains(where: { $0.isCurrentUser }) { return true }
                return false
            }
            .sorted { $0.startDate < $1.startDate }

        return events.first
    }

    /// Extracts video conference links from an event
    func extractVideoLink(from event: EKEvent) -> URL? {
        // Common video conference URL patterns
        let patterns = [
            "https://[a-zA-Z0-9.-]*zoom\\.us/[^\\s\"<>]+",
            "https://meet\\.google\\.com/[a-zA-Z0-9-]+",
            "https://teams\\.microsoft\\.com/[^\\s\"<>]+",
            "https://[a-zA-Z0-9.-]*webex\\.com/[^\\s\"<>]+",
            "https://[a-zA-Z0-9.-]*gotomeeting\\.com/[^\\s\"<>]+",
            "https://[a-zA-Z0-9.-]*chime\\.aws/[^\\s\"<>]+",
            "https://[a-zA-Z0-9.-]*whereby\\.com/[^\\s\"<>]+",
            "https://[a-zA-Z0-9.-]*around\\.co/[^\\s\"<>]+",
        ]

        let combinedPattern = patterns.joined(separator: "|")

        // Check the event URL first
        if let url = event.url, isVideoLink(url) {
            return url
        }

        // Search in notes
        if let notes = event.notes, let url = findURL(in: notes, pattern: combinedPattern) {
            return url
        }

        // Search in location
        if let location = event.location, let url = findURL(in: location, pattern: combinedPattern) {
            return url
        }

        // Fallback: look for any https link in notes/location
        let genericPattern = "https://[^\\s\"<>]+"
        if let notes = event.notes, let url = findURL(in: notes, pattern: genericPattern) {
            return url
        }
        if let location = event.location, let url = findURL(in: location, pattern: genericPattern) {
            return url
        }

        return nil
    }

    private func isVideoLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com",
                          "gotomeeting.com", "chime.aws", "whereby.com", "around.co"]
        return videoHosts.contains(where: { host.contains($0) })
    }

    private func findURL(in text: String, pattern: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            let matchRange = Range(match.range, in: text)!
            return URL(string: String(text[matchRange]))
        }
        return nil
    }
}
