import Foundation
import EventKit

/// Read-only wrapper over `EKEventStore` for auto-naming meeting transcripts
/// and showing today's events in the tray.
///
/// - Resolves "current event" as the one whose time window contains
///   `Date()` ± `currentWindow` (default 5 min). This lets the user click
///   Start meeting up to 5 min before/after the event boundary and still get
///   the right auto-name + header.
/// - Parses Zoom / Meet / Teams / generic-https conferencing URLs from the
///   event's `notes`, `url`, and `location`.
/// - Stays silent on permission denial — `todaysEvents()` returns empty,
///   `currentEvent()` returns nil. The meeting flow falls back to the
///   generic timestamped filename.
@MainActor
final class CalendarBridge {

    static let shared = CalendarBridge()

    private let store = EKEventStore()
    private let currentWindow: TimeInterval = 5 * 60  // 5 minutes

    /// Snapshot of a single event in a form convenient for downstream code —
    /// detached from EventKit so we don't drag `EKEvent` references around.
    struct Event: Equatable {
        let identifier: String
        let title: String
        let startDate: Date
        let endDate: Date
        let attendees: [String]
        /// First conference URL found in notes / url / location, if any.
        let conferenceURL: URL?
        /// Display name of the source calendar (e.g. "Google – work@…").
        let calendarSource: String

        /// File-safe slug derived from the title.
        /// `"Standup with Anya & Boris"` → `"standup-with-anya-boris"`.
        var filenameSlug: String {
            let lower = title.lowercased()
            var allowed = CharacterSet.lowercaseLetters
            allowed.insert(charactersIn: "0123456789-")
            let cleaned = lower.unicodeScalars.map { scalar -> Character in
                allowed.contains(scalar) ? Character(scalar) : "-"
            }
            // Collapse runs of `-` and trim edges.
            let collapsed = String(cleaned)
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
            // Cap length so filename stays under common path limits.
            return String(collapsed.prefix(60))
        }
    }

    // MARK: - Authorization

    /// Current authorization status — never throws, never prompts.
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// True if we currently have permission to read events.
    var isAuthorized: Bool {
        let s = authorizationStatus
        if #available(macOS 14.0, *) {
            return s == .fullAccess || s == .writeOnly
        }
        return s == .authorized
    }

    /// Request access, prompting the user if undetermined. Idempotent.
    /// Returns true if granted (or already granted).
    func requestAccess() async -> Bool {
        switch authorizationStatus {
        case .notDetermined:
            // macOS 14+ uses `requestFullAccessToEvents`; earlier macOS uses
            // `requestAccess(to:)`. We only target 14+ so use the new API.
            if #available(macOS 14.0, *) {
                do {
                    let granted = try await store.requestFullAccessToEvents()
                    TrayLog.append("calendar: permission \(granted ? "granted" : "denied")")
                    return granted
                } catch {
                    TrayLog.append("calendar: permission request error — \(error.localizedDescription)")
                    return false
                }
            } else {
                // Fallback path; should be unreachable given our deployment target.
                return await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { granted, _ in
                        cont.resume(returning: granted)
                    }
                }
            }
        default:
            return isAuthorized
        }
    }

    // MARK: - Queries

    /// Events between today 00:00 and tomorrow 00:00, sorted by start time.
    /// Returns empty if permission is missing — never throws.
    func todaysEvents() -> [Event] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        let predicate = store.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        let raw = store.events(matching: predicate)
        return raw
            .sorted { $0.startDate < $1.startDate }
            .map { snapshot(from: $0) }
    }

    /// Event whose [start, end] window contains `Date()` ± `currentWindow`.
    /// If multiple match (e.g. overlapping events), returns the one starting
    /// soonest from the timestamp anchor — heuristic for the "main" call.
    func currentEvent(at date: Date = Date()) -> Event? {
        guard isAuthorized else { return nil }
        let windowStart = date.addingTimeInterval(-currentWindow)
        let windowEnd = date.addingTimeInterval(currentWindow)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        let matches = store.events(matching: predicate)
        let bestMatch = matches.min { lhs, rhs in
            abs(lhs.startDate.timeIntervalSince(date)) < abs(rhs.startDate.timeIntervalSince(date))
        }
        return bestMatch.map { snapshot(from: $0) }
    }

    // MARK: - Internal mapping

    private func snapshot(from ek: EKEvent) -> Event {
        let names = (ek.attendees ?? []).compactMap { participant -> String? in
            // Display name preferred; fall back to email part of mailto:
            if let s = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
            let url = participant.url
            if url.scheme == "mailto" {
                // mailto:foo@bar.com → take everything after the colon
                let raw = url.absoluteString
                if let colon = raw.firstIndex(of: ":") {
                    let email = String(raw[raw.index(after: colon)...])
                    return email.isEmpty ? nil : email
                }
            }
            return nil
        }
        return Event(
            identifier: ek.eventIdentifier ?? UUID().uuidString,
            title: ek.title ?? "(untitled)",
            startDate: ek.startDate,
            endDate: ek.endDate,
            attendees: names,
            conferenceURL: extractConferenceURL(notes: ek.notes, url: ek.url, location: ek.location),
            calendarSource: ek.calendar.source.title
        )
    }

    /// Walk notes → url → location, return the first match against known
    /// conferencing host patterns. Generic https URLs in notes also win if
    /// nothing more specific is found.
    private func extractConferenceURL(notes: String?, url: URL?, location: String?) -> URL? {
        let candidates: [String] = [notes, url?.absoluteString, location].compactMap { $0 }
        // First pass: known conference hosts.
        let knownHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com",
                          "teams.live.com", "whereby.com", "discord.gg",
                          "discord.com", "around.co"]
        for source in candidates {
            for url in urls(in: source) where knownHosts.contains(where: { url.absoluteString.lowercased().contains($0) }) {
                return url
            }
        }
        // Second pass: any https URL from notes (in case the call is on a
        // custom domain — common with company-internal video tools).
        if let notes, let first = urls(in: notes).first {
            return first
        }
        return nil
    }

    private func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }
}
