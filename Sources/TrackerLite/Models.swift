// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

// MARK: - stored model
//
// Everything TrackerLite knows lives in one small JSON file (see SessionStore):
// a list of projects and a flat list of sessions. A session with a nil `end` is
// the one currently running — persisting it means quitting or crashing
// mid-session doesn't lose the clock.
//
// The file syncs between Macs through iCloud Drive, so every record carries
// when it last changed (`updated`) and deletions are remembered: two copies
// merge record by record (see TrackerData.merged) instead of one overwriting
// the other.

/// A thing you work on. Sessions reference it by id, so renaming a project
/// relabels its whole history and archiving it keeps that history readable.
struct Project: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Index into `projectPalette` — the default color, assigned on creation.
    var colorIndex: Int = 0
    /// A custom color picked from the system color panel, `#RRGGBB`. Wins over
    /// `colorIndex` when set; clearing it falls back to the palette. Optional so
    /// files written before custom colors existed still decode.
    var colorHex: String? = nil
    /// Hidden from the picker but still names past sessions.
    var archived: Bool = false
    /// Target time per day or week; nil = no goal.
    var goalMinutes: Int? = nil
    var goalPeriod: Period? = nil
    /// A daily goal that doesn't apply on Saturdays and Sundays.
    var goalWeekdaysOnly: Bool? = nil
    /// Last change, for merging copies from other Macs. Optional so files from
    /// before sync still decode (treated as oldest).
    var updated: Date? = nil

    var color: Color {
        colorHex.flatMap(Color.init(hex:)) ?? projectPalette[abs(colorIndex) % projectPalette.count]
    }
}

let projectPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .cyan, .red]

extension Color {
    /// `#RRGGBB` in sRGB, for storing a picked color in the JSON file.
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let f = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", f(c.redComponent), f(c.greenComponent), f(c.blueComponent))
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// One stretch of work. `end == nil` ⇒ running right now.
struct Session: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var projectID: UUID?      // nil ⇒ unlabeled
    var note: String = ""
    var start: Date
    var end: Date?
    /// Last change, for merging copies from other Macs (see Project.updated).
    var updated: Date? = nil

    var isRunning: Bool { end == nil }

    /// Elapsed time, measured to `now` while running.
    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    /// How much of this session falls inside `range` — so a session that crosses
    /// midnight is counted against each day in the right proportion.
    func overlap(_ range: Range<Date>, now: Date = Date()) -> TimeInterval {
        let stop = end ?? now
        let lo = max(start, range.lowerBound)
        let hi = min(stop, range.upperBound)
        return max(0, hi.timeIntervalSince(lo))
    }
}

/// The whole file: projects + sessions, plus the ids of deleted sessions (and
/// when) so a merge doesn't bring them back from another Mac's copy.
struct TrackerData: Codable, Equatable {
    var projects: [Project] = []
    var sessions: [Session] = []
    var deletedSessions: [String: Date] = [:]   // session id → when

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        deletedSessions = try c.decodeIfPresent([String: Date].self, forKey: .deletedSessions) ?? [:]
    }

    /// This copy merged with another Mac's: each project and session keeps its
    /// most recently changed version, deletions win over older edits, and
    /// projects keep this copy's order. Deterministic, so both Macs converge.
    func merged(with other: TrackerData) -> TrackerData {
        var out = TrackerData()
        out.deletedSessions = deletedSessions.merging(other.deletedSessions) { max($0, $1) }

        let theirProjects = Dictionary(other.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Set(projects.map(\.id))
        out.projects = projects.map { p in theirProjects[p.id].map { Self.newer(p, $0) } ?? p }
            + other.projects.filter { !mine.contains($0.id) }

        var byID: [UUID: Session] = [:]
        for s in sessions + other.sessions {
            byID[s.id] = byID[s.id].map { Self.newer($0, s) } ?? s
        }
        out.sessions = byID.values
            .filter { s in out.deletedSessions[s.id.uuidString].map { $0 < (s.updated ?? .distantPast) } ?? true }
            .sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        out.endOverlappingTimers()
        return out
    }

    /// Timers started on two Macs at once: the newest keeps running and ends
    /// the others where it began, so no time is counted twice.
    private mutating func endOverlappingTimers() {
        let running = sessions.indices.filter { sessions[$0].isRunning }
        guard let newest = running.max(by: { sessions[$0].start < sessions[$1].start }) else { return }
        let cutoff = sessions[newest].start
        for i in running where i != newest {
            sessions[i].end = max(cutoff, sessions[i].start)
            sessions[i].updated = cutoff
        }
    }

    /// The more recently changed of two versions of one record; ties break on
    /// content so every Mac picks the same one.
    private static func newer<T: Stamped>(_ a: T, _ b: T) -> T {
        let (ua, ub) = (a.updated ?? .distantPast, b.updated ?? .distantPast)
        if ua != ub { return ua > ub ? a : b }
        return a.fingerprint >= b.fingerprint ? a : b
    }
}

protocol Stamped: Encodable { var updated: Date? { get } }
extension Project: Stamped {}
extension Session: Stamped {}

private extension Encodable {
    var fingerprint: String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - panel screens

/// Which screen the panel is showing. (Named PanelTab to avoid SwiftUI's `Tab`.)
enum PanelTab: String, CaseIterable, Identifiable {
    case track, stats
    var id: String { rawValue }
    var title: String { self == .track ? "Track" : "Stats" }
    var icon: String { self == .track ? "timer" : "chart.bar.fill" }
}

// MARK: - periods

/// The window the Stats screen totals over — and the step its trend bars walk.
enum Period: String, CaseIterable, Identifiable, Codable {
    case day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    /// Heading over the big total.
    var currentLabel: String {
        switch self {
        case .day:   return "Today"
        case .week:  return "This week"
        case .month: return "This month"
        }
    }

    /// The calendar step between trend bars.
    var step: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        }
    }

    /// How many buckets the trend chart shows, ending with the current one.
    var trendCount: Int { self == .day ? 7 : 6 }

    /// The calendar range for the period containing `date`.
    func range(containing date: Date, calendar: Calendar = .current) -> Range<Date> {
        if let i = calendar.dateInterval(of: step, for: date) {
            return i.start..<i.end
        }
        let s = calendar.startOfDay(for: date)
        return s..<(calendar.date(byAdding: .day, value: 1, to: s) ?? date)
    }

    /// Short axis label for a bucket, e.g. "M" (day), "Jul 21" (week), "Jul".
    func axisLabel(for date: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .day:   return Formatters.weekdayLetter.string(from: date)
        case .week:  return Formatters.monthDay.string(from: date)
        case .month: return Formatters.month.string(from: date)
        }
    }
}

// MARK: - formatting

/// These run every second while the panel is open (the 1s tick redraws every
/// row), and formatters are costly to create — so build each once.
private enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let weekdayLetter = fixed("EEEEE")
    static let monthDay = fixed("M/d")
    static let month = fixed("MMM")
    static let weekdayDate = fixed("EEE, MMM d")
    private static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
}

/// "9:15 AM – 10:02 AM", or "9:15 AM – now" while still running.
private func span(_ from: Date, _ to: Date?) -> String {
    let start = Formatters.time.string(from: from)
    guard let to else { return "\(start) – now" }
    return "\(start) – \(Formatters.time.string(from: to))"
}

/// Human total, e.g. "2h 14m", "43m", "—" when zero.
func hm(_ t: TimeInterval) -> String {
    let mins = Int((t / 60).rounded())
    if mins <= 0 { return "—" }
    let (h, m) = (mins / 60, mins % 60)
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

/// Running clock, e.g. "12:34" (m:ss) or "1:02:03" (h:m:ss).
func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}

/// Compact menu-bar clock — minute granularity, e.g. "0:07", "1:23".
func hmShort(_ t: TimeInterval) -> String {
    let mins = max(0, Int(t / 60))
    return String(format: "%d:%02d", mins / 60, mins % 60)
}

/// Start–end time range for a session row, e.g. "9:15 AM – 10:02 AM".
func timeRange(_ s: Session) -> String { span(s.start, s.end) }

/// Span of a merged row: earliest start to latest end, e.g. "6:42 AM – 3:30 PM".
func timeSpan(_ g: SessionGroup) -> String { span(g.startedAt, g.endedAt) }

/// Day header for a session group, e.g. "Today", "Yesterday", "Mon, Jul 21".
func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day],
        from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Yesterday"
    default:
        return Formatters.weekdayDate.string(from: day)
    }
}

// MARK: - derived rows

/// One project's slice of a period — what the Stats breakdown lists.
struct ProjectTotal: Identifiable {
    let id: String          // project id, or "unlabeled"
    let name: String
    let color: Color
    let seconds: TimeInterval
}

/// A project's goal and how it's going — one ring in the Goals strip.
struct GoalStatus: Identifiable {
    let id: UUID            // project id
    let name: String
    let color: Color
    let done: TimeInterval
    let target: TimeInterval
    let period: Period
    let weekdaysOnly: Bool
    /// A weekend, for a weekdays-only goal.
    let restDay: Bool
    let streak: Int

    var met: Bool { done >= target }
    var fraction: Double { min(done / target, 1) }
}

/// One bar in the trend chart.
struct TrendBucket: Identifiable {
    let id: Int             // index, oldest → newest
    let label: String
    let seconds: TimeInterval
    let isCurrent: Bool
}

/// Sessions in one day that share a project *and* a note, folded into a single
/// history row. Stopping and restarting the same task five times is one thing
/// you did, not five — the row shows the summed time and the whole span, and its
/// actions (retag, delete, start again) apply to every session in it.
///
/// This is a view of the data, not a rewrite of it: `data.json` keeps each
/// session exactly as it was recorded, so Stats and the day totals are unchanged.
struct SessionGroup: Identifiable {
    /// Newest first, never empty.
    let sessions: [Session]

    var id: UUID { sessions[0].id }
    var projectID: UUID? { sessions[0].projectID }
    var note: String { sessions[0].note }
    var count: Int { sessions.count }

    var startedAt: Date { sessions.map(\.start).min() ?? sessions[0].start }
    /// nil while any session in the row is still running.
    var endedAt: Date? {
        let ends = sessions.map(\.end)
        return ends.contains(where: { $0 == nil }) ? nil : ends.compactMap { $0 }.max()
    }

    func seconds(now: Date) -> TimeInterval {
        sessions.reduce(0) { $0 + $1.duration(now: now) }
    }

    /// The key two sessions must share to merge: same project, same note
    /// (trimmed and case-insensitive, so "paper" and "Paper " are one task).
    static func key(_ s: Session) -> String {
        let note = s.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(s.projectID?.uuidString ?? "-")|\(note)"
    }
}

/// A day's worth of sessions, newest day first (the Track screen's history).
struct DayGroup: Identifiable {
    let id: Date            // start of day
    let title: String
    let seconds: TimeInterval
    let items: [SessionGroup]
}

/// The session editor's contents. `id == nil` is a new session logged after the
/// fact; a running session's end isn't editable (it's still going).
struct SessionDraft: Equatable {
    var id: UUID?
    var projectID: UUID?
    var note: String
    var start: Date
    var end: Date
    var isRunning: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func isValid(now: Date) -> Bool {
        isRunning ? start < now : end > start && start <= now
    }

    static func roundedDown(_ d: Date, minutes: Int = 5) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        c.minute = ((c.minute ?? 0) / minutes) * minutes
        return cal.date(from: c) ?? d
    }
}
