// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI

/// Every project with a goal, as a row of rings filling up through the day (or
/// week), then a "+ Goal" tile. Tap a ring to change its goal. With no goals
/// yet, it's a single slim "set a goal" button.
struct GoalsStrip: View {
    @EnvironmentObject var state: AppState

    private func edit(_ id: UUID) {
        withAnimation(Motion.screen) {
            state.styledProjectID = id
            state.showingColorPicker = false
            state.showingProjectList = false
            state.showingGoalEditor = true
        }
    }

    /// The project a new goal is for: the one you're on, unless it already has
    /// a goal — then the first one that doesn't.
    private var newGoalProject: UUID? {
        let open = state.projects.filter { $0.goalMinutes == nil }
        if let a = state.activeProjectID, open.contains(where: { $0.id == a }) { return a }
        return open.first?.id
    }

    var body: some View {
        let goals = state.goals
        if goals.isEmpty {
            Button { if let id = newGoalProject { edit(id) } } label: {
                Label("Set a daily or weekly goal", systemImage: "target")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(goals) { g in
                        Button { edit(g.id) } label: {
                            GoalRing(goal: g, active: g.id == state.activeProjectID)
                        }
                        .buttonStyle(.plain)
                        .help(help(g))
                    }
                    if let id = newGoalProject {
                        Button { edit(id) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                                Text("Goal").font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: 44).frame(maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add a goal")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.never)
            .scrollDisabled(goals.count <= 3)
        }
    }

    private func help(_ g: GoalStatus) -> String {
        var lines = ["\(g.name): \(hm(g.done)) of \(hm(g.target)) \(g.period == .day ? "today" : "this week")"]
        if g.restDay { lines = ["\(g.name): weekdays only — no goal today"] }
        if g.streak > 1 { lines.append("\(g.streak) \(g.period == .day ? "days" : "weeks") in a row") }
        lines.append("Click to change the goal")
        return lines.joined(separator: "\n")
    }
}

private struct GoalRing: View {
    let goal: GoalStatus
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: goal.restDay ? 0 : goal.fraction)
                    .stroke(goal.met ? Color.green : goal.color,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if goal.met && !goal.restDay {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else if goal.restDay {
                    Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("\(Int(goal.fraction * 100))%")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .animation(Motion.quick, value: goal.fraction)

            Text(goal.name).font(.system(size: 10, weight: active ? .semibold : .regular)).lineLimit(1)
            HStack(spacing: 3) {
                Text(goal.restDay ? "rest day" : "\(short(goal.done))/\(short(goal.target))")
                    .monospacedDigit()
                if goal.streak > 1 {
                    Text("🔥\(goal.streak)")
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 63)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(active ? 0.08 : 0.04)))
    }

    /// "1h20", "45m", "3h" — tight enough for a ring caption.
    private func short(_ t: TimeInterval) -> String {
        let mins = Int((t / 60).rounded())
        let (h, m) = (mins / 60, mins % 60)
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }
}

/// Set a project's goal: a day or a week, a preset (or nudge it in 15/30-minute
/// steps), and for daily goals whether weekends count. Applies as you click,
/// like the color row.
struct GoalRow: View {
    @EnvironmentObject var state: AppState
    let projectID: UUID

    private var project: Project? { state.project(projectID) }
    private var minutes: Int? { project?.goalMinutes }
    private var period: Period { project?.goalPeriod ?? pendingPeriod }
    private var weekdaysOnly: Bool { project?.goalWeekdaysOnly ?? false }
    /// The Day/Week choice before any goal is set.
    @State private var pendingPeriod: Period = .day

    private static let presets: [Period: [Int]] = [
        .day: [60, 120, 180, 240, 360],
        .week: [300, 600, 900, 1200, 1800],
    ]

    private func set(_ m: Int?, _ p: Period? = nil, weekdays: Bool? = nil) {
        state.setGoal(projectID, minutes: m, period: p ?? period, weekdaysOnly: weekdays ?? weekdaysOnly)
    }

    private func nudge(_ m: Int, up: Bool) -> Int {
        let size = (up ? m : m - 1) < 60 ? 15 : 30
        return max(15, up ? m + size : m - size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Switch which project you're setting a goal for.
                Menu {
                    ForEach(state.projects) { p in
                        Button(p.goalMinutes == nil ? p.name : "\(p.name)  ·  \(hm(TimeInterval(p.goalMinutes! * 60)))") {
                            state.styledProjectID = p.id
                            pendingPeriod = p.goalPeriod ?? .day
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(state.color(projectID)).frame(width: 7, height: 7)
                        Text(state.name(projectID)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer(minLength: 4)
                Text(minutes.map { "\(hm(TimeInterval($0 * 60))) a \(period == .day ? "day" : "week")" } ?? "No goal")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(minutes == nil ? .tertiary : .secondary)
                Button { withAnimation(Motion.screen) { state.showingGoalEditor = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Done")
            }

            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { period }, set: { p in
                    pendingPeriod = p
                    // Switching keeps the goal's size sensible: a day's goal × 5
                    // for a week, a week's ÷ 5 for a day.
                    if let m = minutes { set(p == .week ? m * 5 : max(15, m / 5), p) }
                })) {
                    Text("Day").tag(Period.day)
                    Text("Week").tag(Period.week)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
                Button { if let m = minutes { set(nudge(m, up: false)) } } label: {
                    Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).disabled(minutes == nil)
                Button { set(minutes.map { nudge($0, up: true) } ?? Self.presets[period]![1]) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(Self.presets[period]!, id: \.self) { m in
                    let on = minutes == m
                    Button { set(m) } label: {
                        Text(hm(TimeInterval(m * 60)))
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .foregroundStyle(on ? Color.white : .primary)
                            .background(Capsule().fill(on ? AnyShapeStyle(pillFill()) : AnyShapeStyle(.white.opacity(0.07))))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                if period == .day {
                    Toggle(isOn: Binding(get: { weekdaysOnly }, set: { set(minutes ?? Self.presets[.day]![1], weekdays: $0) })) {
                        Text("Weekdays only").font(.system(size: 11))
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                }
                Spacer(minLength: 0)
                if minutes != nil {
                    Button("Remove goal") { set(nil) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red.opacity(0.85))
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        .onAppear { pendingPeriod = project?.goalPeriod ?? .day }
    }
}
