// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// Central observable state: owns the JSON store, the running session, and the
/// once-a-second tick that drives every live duration in the UI and menu bar.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var data = TrackerData() { didSet { store.save(data) } }

    /// Ticks every second while a session runs or the panel is open — everything
    /// that shows a live elapsed time reads durations against this, so there's a
    /// single clock and no per-view timers.
    @Published var now = Date()

    @Published var tab: PanelTab = .track {
        didSet { if tab != .track { sessionDraft = nil }; applyCachedHeight() }
    }
    /// Whether the panel is open — keeps the 1s ticker alive for live durations.
    @Published var panelVisible = false { didSet { syncTicker() } }

    /// The composer: what the next session gets labeled with (remembered, so
    /// start/stop/start on the same thing is two clicks).
    @Published var draftProjectID: UUID? = {
        guard let s = UserDefaults.standard.string(forKey: "draftProjectID") else { return nil }
        return UUID(uuidString: s)
    }() {
        didSet { UserDefaults.standard.set(draftProjectID?.uuidString, forKey: "draftProjectID") }
    }
    @Published var draftNote = ""
    /// Inline "new project" field in the project menu.
    @Published var newProjectName = ""
    @Published var showingNewProject = false { didSet { applyCachedHeight() } }
    /// Inline color row under the project chip.
    @Published var showingColorPicker = false { didSet { applyCachedHeight() } }
    /// Inline project list (replaces a `Menu` — see ProjectChip).
    @Published var showingProjectList = false { didSet { applyCachedHeight() } }
    /// Inline goal editor under the project chip.
    @Published var showingGoalEditor = false { didSet { applyCachedHeight() } }
    /// The project the color/goal rows edit — one picked from the list, else
    /// the active one. (While a session runs the list can style any project.)
    @Published var styledProjectID: UUID?
    var styleTargetID: UUID? { styledProjectID ?? activeProjectID }

    @Published var period: Period =
        Period(rawValue: UserDefaults.standard.string(forKey: "statsPeriod") ?? "") ?? .day {
        didSet {
            UserDefaults.standard.set(period.rawValue, forKey: "statsPeriod")
            applyCachedHeight()
        }
    }

    /// Closes the panel. Set by StatusController so SwiftUI can dismiss without
    /// knowing about AppKit.
    var closePanel: (() -> Void)?

    /// Stop the clock once the mouse and keyboard have been quiet this long —
    /// a running timer over an empty chair is the main way these numbers go bad.
    let idleLimit: TimeInterval = 120

    @Published var autoStopWhenIdle: Bool =
        UserDefaults.standard.object(forKey: "autoStopWhenIdle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStopWhenIdle, forKey: "autoStopWhenIdle") }
    }

    /// Set when the clock stopped itself, cleared on the next manual start —
    /// the Track screen says so, since an auto-stop is easy to miss.
    @Published private(set) var lastAutoStop: Date?

    private let store = SessionStore()
    private var ticker: Timer?
    private let calendar: Calendar = {
        // The demo's weeks start Monday, so a Sunday screenshot still shows a
        // full week.
        var c = Calendar.current
        if Demo.on { c.firstWeekday = 2 }
        return c
    }()

    init() {
        data = store.load()
        primePanelSize()
        syncTicker()
        // Another Mac's changes arrive through iCloud Drive: fold them in.
        store.watch { [weak self] disk in
            MainActor.assumeIsolated {
                guard let self else { return }
                let merged = self.data.merged(with: disk)
                if merged != self.data { self.data = merged; self.syncTicker() }
            }
        }
        // Re-tick when the machine wakes: a session started before sleep should
        // show the true elapsed time immediately, not a stale one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
    }

    /// One 1s timer, alive only when something on screen is actually counting.
    private func syncTicker() {
        let wanted = running != nil || panelVisible
        if wanted, ticker == nil {
            now = Date()
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            t.tolerance = 0.2
            ticker = t
        } else if !wanted {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        now = Date()
        checkIdle()
    }

    /// Auto-stop. The session ends at the *last input*, not at the moment we
    /// notice: the quiet stretch was never work, so it shouldn't be counted.
    /// That also makes detection latency harmless — if App Nap throttles the
    /// tick while you're away, a late check still writes the same end time.
    private func checkIdle() {
        // The demo's session keeps running on an idle screenshot machine.
        guard autoStopWhenIdle, !Demo.on, let r = running else { return }
        let idle = IdleMonitor.idleSeconds
        guard idle >= idleLimit else { return }
        stop(r, at: now.addingTimeInterval(-idle))
        lastAutoStop = Date()
    }

    // MARK: - edits (each stamps `updated`, so the newest edit wins a merge)

    private func editProject(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        var p = data.projects[i]
        change(&p)
        p.updated = Date()
        data.projects[i] = p
    }

    private func editSessions(_ ids: Set<UUID>, _ change: (inout Session) -> Void) {
        let stamp = Date()
        var sessions = data.sessions
        for i in sessions.indices where ids.contains(sessions[i].id) {
            change(&sessions[i])
            sessions[i].updated = stamp
        }
        data.sessions = sessions
    }

    /// Remove sessions, remembering the deletion so a merge doesn't revive them.
    private func removeSessions(_ ids: Set<UUID>) {
        let stamp = Date()
        var d = data
        d.sessions.removeAll { ids.contains($0.id) }
        for id in ids { d.deletedSessions[id.uuidString] = stamp }
        data = d
        syncTicker()
    }

    // MARK: - projects

    var projects: [Project] { data.projects.filter { !$0.archived } }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return data.projects.first { $0.id == id }
    }

    func name(_ id: UUID?) -> String { project(id)?.name ?? "Unlabeled" }
    func color(_ id: UUID?) -> Color { project(id)?.color ?? .secondary }

    /// Create a project (next palette color) and select it for the next session.
    @discardableResult
    func addProject(_ rawName: String) -> Project? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Re-select (and un-archive) an existing project instead of duplicating it.
        if let i = data.projects.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            editProject(data.projects[i].id) { $0.archived = false }
            draftProjectID = data.projects[i].id
            return data.projects[i]
        }
        let p = Project(name: name, colorIndex: data.projects.count, updated: Date())
        data.projects.append(p)
        draftProjectID = p.id
        return p
    }

    func rename(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        editProject(id) { $0.name = name }
    }

    /// Hide a project from the picker. Its sessions keep their label — archiving
    /// rather than deleting is what makes the history stay readable.
    func archive(_ id: UUID) {
        editProject(id) { $0.archived = true }
        if draftProjectID == id { draftProjectID = projects.first?.id }
    }

    /// Pick one of the eight built-in colors. Stored as an index (not a hex) so
    /// it stays semantic and follows any future palette tweak.
    func setPaletteColor(_ id: UUID, index: Int) {
        editProject(id) { $0.colorIndex = index; $0.colorHex = nil }
    }

    /// Pick an arbitrary color (the system color panel), stored as `#RRGGBB`.
    func setCustomColor(_ id: UUID, _ color: Color) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }),
              let hex = color.hexString else { return }
        // No-op writes would churn the JSON file while the color panel drags.
        guard data.projects[i].colorHex != hex else { return }
        editProject(id) { $0.colorHex = hex }
    }

    /// Which palette swatch is selected, or nil when a custom color is in use.
    func paletteIndex(_ id: UUID?) -> Int? {
        guard let p = project(id), p.colorHex == nil else { return nil }
        return abs(p.colorIndex) % projectPalette.count
    }

    /// The project the timer card is about: the running session's, else the draft.
    var activeProjectID: UUID? { running?.projectID ?? draftProjectID }

    // MARK: - goals

    func setGoal(_ id: UUID, minutes: Int?, period: Period, weekdaysOnly: Bool = false) {
        editProject(id) {
            $0.goalMinutes = minutes
            $0.goalPeriod = minutes == nil ? nil : period
            $0.goalWeekdaysOnly = minutes != nil && period == .day && weekdaysOnly ? true : nil
        }
    }

    /// Time logged on a project in the period containing `date` (default now).
    func seconds(project id: UUID?, in period: Period, containing date: Date? = nil) -> TimeInterval {
        let range = period.range(containing: date ?? now, calendar: calendar)
        return data.sessions.reduce(0) { $1.projectID == id ? $0 + $1.overlap(range, now: now) : $0 }
    }

    /// Every active project with a goal, with today's (or this week's) progress
    /// and its streak — what the Goals strip on the Track screen shows.
    var goals: [GoalStatus] {
        projects.compactMap { p in
            guard let m = p.goalMinutes, m > 0, let period = p.goalPeriod else { return nil }
            let target = TimeInterval(m * 60)
            let weekdaysOnly = p.goalWeekdaysOnly ?? false
            let restDay = weekdaysOnly && calendar.isDateInWeekend(now)
            return GoalStatus(id: p.id, name: p.name, color: p.color,
                              done: seconds(project: p.id, in: period), target: target,
                              period: period, weekdaysOnly: weekdaysOnly, restDay: restDay,
                              streak: streak(p.id, target: target, period: period, weekdaysOnly: weekdaysOnly))
        }
    }

    /// Days (or weeks) in a row the goal was met, ending with the last finished
    /// one — plus the current one once it's met, so an unfinished today doesn't
    /// break the streak. Weekends don't count either way for weekdays-only goals.
    private func streak(_ id: UUID, target: TimeInterval, period: Period, weekdaysOnly: Bool) -> Int {
        let skip = { (d: Date) in period == .day && weekdaysOnly && self.calendar.isDateInWeekend(d) }
        var count = 0
        var date = now
        if !skip(date), seconds(project: id, in: period, containing: date) >= target { count += 1 }
        for _ in 0..<400 {
            guard let prev = calendar.date(byAdding: period.step, value: -1, to: date) else { break }
            date = prev
            if skip(date) { continue }
            guard seconds(project: id, in: period, containing: date) >= target else { break }
            count += 1
        }
        return count
    }

    // MARK: - the clock

    var running: Session? { data.sessions.last(where: { $0.isRunning }) }

    var runningElapsed: TimeInterval { running?.duration(now: now) ?? 0 }

    /// The one button. Starts a session labeled with the composer, or stops the
    /// running one (discarding sub-5s taps, which are always misclicks).
    func toggle() {
        if let r = running {
            stop(r)
        } else {
            start()
        }
    }

    func start() {
        guard running == nil else { return }
        let s = Session(projectID: draftProjectID,
                        note: draftNote.trimmingCharacters(in: .whitespacesAndNewlines),
                        start: Date(), updated: Date())
        data.sessions.append(s)
        lastAutoStop = nil
        syncTicker()
    }

    /// `at` lets the idle check backdate the end to the last input; everything
    /// else stops in the present.
    private func stop(_ session: Session, at when: Date = Date()) {
        guard data.sessions.contains(where: { $0.id == session.id }) else { return }
        let end = max(when, session.start)
        if end.timeIntervalSince(session.start) < 5 {
            removeSessions([session.id])      // a misclick, not a session
        } else {
            editSessions([session.id]) { $0.end = end }
        }
        syncTicker()
    }

    /// Change project mid-session: the running session ends and a new one starts
    /// on the new project. Within its first minute it's just retagged — that's
    /// fixing a wrong pick, not switching tasks.
    func switchProject(to id: UUID?) {
        draftProjectID = id
        guard let r = running, r.projectID != id else { return }
        if r.duration(now: Date()) < 60 {
            editSessions([r.id]) { $0.projectID = id }
        } else {
            stop(r)
            draftNote = ""
            start()
        }
    }

    /// Start a fresh session with a past one's label — the "again" button.
    func resume(_ session: Session) {
        if let r = running { stop(r) }
        draftProjectID = session.projectID
        draftNote = session.note
        start()
    }

    func delete(_ session: Session) { removeSessions([session.id]) }

    /// Retag a logged session (used by the row's context menu).
    func setProject(_ id: UUID?, for session: Session) {
        editSessions([session.id]) { $0.projectID = id }
    }

    // A merged history row stands for every session inside it, so its actions
    // hit all of them — otherwise "delete" would leave four invisible copies.

    func delete(_ group: SessionGroup) { removeSessions(Set(group.sessions.map(\.id))) }

    func setProject(_ id: UUID?, for group: SessionGroup) {
        editSessions(Set(group.sessions.map(\.id))) { $0.projectID = id }
    }

    /// Edit the running session's note live from the composer field.
    func setRunningNote(_ text: String) {
        guard let r = running else { return }
        editSessions([r.id]) { $0.note = text }
    }

    // MARK: - session editor (fix a session's times, or log one after the fact)

    /// The session being edited or added; non-nil shows the editor.
    @Published var sessionDraft: SessionDraft? { didSet { applyCachedHeight() } }

    func beginEdit(_ s: Session) {
        sessionDraft = SessionDraft(id: s.id, projectID: s.projectID, note: s.note,
                                    start: s.start, end: s.end ?? Date(), isRunning: s.isRunning)
    }

    /// A new past session: the hour before now, on the current project.
    func beginAddSession() {
        let end = SessionDraft.roundedDown(Date())
        sessionDraft = SessionDraft(id: nil, projectID: draftProjectID, note: "",
                                    start: end.addingTimeInterval(-3600), end: end, isRunning: false)
    }

    /// Other sessions the draft's times overlap (they'd be counted twice).
    func overlaps(_ d: SessionDraft) -> Int {
        let end = d.isRunning ? now : d.end
        return data.sessions.filter { s in
            s.id != d.id && s.start < end && (s.end ?? now) > d.start
        }.count
    }

    func saveSessionDraft() {
        guard let d = sessionDraft, d.isValid(now: Date()) else { return }
        let note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = d.id {
            editSessions([id]) { s in
                s.projectID = d.projectID; s.note = note; s.start = d.start
                if !d.isRunning { s.end = d.end }
            }
        } else {
            data.sessions.append(Session(projectID: d.projectID, note: note,
                                         start: d.start, end: d.end, updated: Date()))
            data.sessions.sort { $0.start < $1.start }
        }
        sessionDraft = nil
    }

    func deleteSessionDraft() {
        if let id = sessionDraft?.id { removeSessions([id]) }
        sessionDraft = nil
    }

    // MARK: - totals

    /// Total tracked seconds inside a range (sessions crossing a boundary are
    /// counted only for their overlapping part).
    func seconds(in range: Range<Date>) -> TimeInterval {
        data.sessions.reduce(0) { $0 + $1.overlap(range, now: now) }
    }

    func seconds(for p: Period, containing date: Date? = nil) -> TimeInterval {
        seconds(in: p.range(containing: date ?? now, calendar: calendar))
    }

    var todaySeconds: TimeInterval { seconds(for: .day) }
    var weekSeconds: TimeInterval { seconds(for: .week) }
    var monthSeconds: TimeInterval { seconds(for: .month) }

    /// Per-project breakdown of the selected period, largest first.
    var breakdown: [ProjectTotal] { breakdown(period) }

    func breakdown(_ period: Period) -> [ProjectTotal] {
        let range = period.range(containing: now, calendar: calendar)
        var totals: [UUID?: TimeInterval] = [:]
        for s in data.sessions {
            let t = s.overlap(range, now: now)
            if t > 0 { totals[s.projectID, default: 0] += t }
        }
        return totals
            .map { id, secs in
                ProjectTotal(id: id?.uuidString ?? "unlabeled",
                             name: name(id), color: color(id), seconds: secs)
            }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Trend bars for the selected period: the last N buckets, oldest → newest.
    var trend: [TrendBucket] {
        let count = period.trendCount
        return (0..<count).reversed().compactMap { back -> TrendBucket? in
            guard let date = calendar.date(byAdding: period.step, value: -back, to: now)
            else { return nil }
            let range = period.range(containing: date, calendar: calendar)
            return TrendBucket(id: count - 1 - back,
                               label: period.axisLabel(for: range.lowerBound, calendar: calendar),
                               seconds: seconds(in: range),
                               isCurrent: back == 0)
        }
    }

    /// Recent sessions grouped by day, newest first — the Track screen history.
    /// Capped to the last 14 days so the panel stays a panel.
    var recentDays: [DayGroup] {
        let cutoff = calendar.date(byAdding: .day, value: -13,
                                   to: calendar.startOfDay(for: now)) ?? now
        var order: [Date] = []
        var byDay: [Date: [Session]] = [:]
        for s in data.sessions where s.start >= cutoff && !s.isRunning {
            let key = calendar.startOfDay(for: s.start)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(s)
        }
        return order.sorted(by: >).map { day in
            let items = (byDay[day] ?? []).sorted { $0.start > $1.start }
            let range = Period.day.range(containing: day, calendar: calendar)
            return DayGroup(id: day, title: dayHeader(day, now: now, calendar: calendar),
                            seconds: seconds(in: range), items: merged(items))
        }
    }

    /// Fold same-project, same-note sessions into one row each, keeping the
    /// day's order (a row sits where its most recent session does). The day
    /// total above still comes from `seconds(in:)`, so merging can't change it.
    private func merged(_ sessions: [Session]) -> [SessionGroup] {
        var order: [String] = []
        var byKey: [String: [Session]] = [:]
        for s in sessions {                       // already newest first
            let key = SessionGroup.key(s)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(s)
        }
        return order.compactMap { key in
            guard let items = byKey[key], !items.isEmpty else { return nil }
            return SessionGroup(sessions: items)
        }
    }

    // MARK: - misc actions

    /// Sessions overlapping a range as CSV — one row each, local times.
    func exportCSV(_ range: Range<Date>?, label: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TrackerLite \(label).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        func field(_ s: String) -> String {
            s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var rows = ["date,start,end,minutes,project,note"]
        for s in data.sessions where range.map({ s.overlap($0, now: now) > 0 }) ?? true {
            rows.append([day.string(from: s.start), time.string(from: s.start),
                         s.end.map(time.string) ?? "",
                         String(Int((s.duration(now: now) / 60).rounded())),
                         field(name(s.projectID)), field(s.note)].joined(separator: ","))
        }
        try? (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func revealDataFile() {
        NSWorkspace.shared.selectFile(SessionStore.fileURL.path,
                                      inFileViewerRootedAtPath: SessionStore.folder.path)
    }

    /// True for ~1.5s after a copy, so the button can confirm it landed.
    @Published private(set) var justCopied = false
    private var copyToken = 0

    /// What the header's copy button acts on. On Stats it follows the visible
    /// Day/Week/Month selector; on Track — where that selector isn't on screen —
    /// it's always the day, so the button can never claim a period you have no
    /// way to see or change from there.
    var copyPeriod: Period { tab == .track ? .day : period }

    /// Copy a period's breakdown as plain text — the escape hatch for pasting a
    /// day's work into a log or timesheet.
    func copySummary() { copySummary(copyPeriod) }

    func copySummary(_ period: Period) {
        let range = period.range(containing: now, calendar: calendar)
        let start = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
        var lines = ["\(period.currentLabel) (\(start)) — \(hm(seconds(in: range)))"]
        lines += breakdown(period).map { "  \($0.name) — \(hm($0.seconds))" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)

        // Token so a second copy restarts the window instead of the first copy's
        // timer cutting the second one's confirmation short.
        withAnimation(Motion.quick) { justCopied = true }
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copyToken == token else { return }
            withAnimation(Motion.quick) { self.justCopied = false }
        }
    }

    // MARK: - panel sizing
    //
    // Same approach as RemindLite: the glass and all height animation live in
    // SwiftUI (the window is a transparent canvas). A hidden probe reports the
    // current screen's natural height; we cache it per screen so re-visiting one
    // animates from the right place instead of snapping a frame later.

    @Published var screenHeight: CGFloat = 0 { didSet { recomputePanelHeight() } }
    @Published var chromeHeight: CGFloat = 0 {
        didSet {
            recomputePanelHeight()
            if chromeHeight > 0 {
                UserDefaults.standard.set(Double(chromeHeight), forKey: "chromeHeight")
            }
        }
    }
    @Published var panelContentHeight: CGFloat = 0

    /// Measured inner height of the scrolling history, kept here (not in @State)
    /// so it survives the view being rebuilt on a tab switch.
    @Published var historyInnerHeight: CGFloat = 0

    private let panelVPadding = panelPadding * 2   // top + bottom

    /// Cached per screen — and persisted, so the *first* open after launch is
    /// already the right size. In-memory only, the panel opened at a fallback
    /// height and then snapped once the probe measured, which read as a jitter of
    /// everything inside it.
    private var cachedScreenHeights: [String: CGFloat] =
        (UserDefaults.standard.dictionary(forKey: "screenHeights") as? [String: Double])
            .map { $0.mapValues { CGFloat($0) } } ?? [:]

    private func persistScreenHeights() {
        UserDefaults.standard.set(cachedScreenHeights.mapValues { Double($0) },
                                  forKey: "screenHeights")
    }

    private var screenKey: String {
        if tab == .track, let d = sessionDraft {
            return "edit|\(d.id == nil)|\(d.isRunning)|\(overlaps(d) > 0)"
        }
        return tab == .track
            ? "track|\(showingNewProject)|\(showingColorPicker)|\(showingProjectList)|\(showingGoalEditor)"
                + "|\(projects.count)|\(goals.isEmpty)"
            : "stats|\(period.rawValue)"
    }

    /// Seed the sizing from the last launch's measurements before the panel is
    /// ever shown, so it opens at its true height instead of settling into it.
    private func primePanelSize() {
        chromeHeight = CGFloat(UserDefaults.standard.double(forKey: "chromeHeight"))
        if let h = cachedScreenHeights[screenKey] { screenHeight = h }
    }

    private func recomputePanelHeight() {
        let h = chromeHeight + screenHeight + panelVPadding
        if abs(h - panelContentHeight) > 0.5 { panelContentHeight = h }
    }

    /// Called by the hidden probe with the current screen's natural body height.
    func reportScreenHeight(_ h: CGFloat) {
        guard h > 0 else { return }
        if abs((cachedScreenHeights[screenKey] ?? 0) - h) > 0.5 {
            cachedScreenHeights[screenKey] = h
            persistScreenHeights()
        }
        // A few px of tolerance: a 1px correction mid-animation reads as a stutter.
        guard abs(h - screenHeight) > 3 else { return }
        // Probe measurements land a frame after the content changed, so applying
        // them instantly is right — animating would teleport. Smooth animation
        // comes from applyCachedHeight, where the destination is already known.
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { screenHeight = h }
    }

    private func applyCachedHeight() {
        if let h = cachedScreenHeights[screenKey] { screenHeight = h }
    }
}
