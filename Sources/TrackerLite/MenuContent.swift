// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header — measured once so the window knows the chrome height.
            // It lives outside the height-animated body, so it can never be
            // clipped or briefly overlaid during a transition.
            VStack(spacing: 0) {
                TabBar()
                Divider().opacity(0.35)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                state.chromeHeight = h
            }

            bodyArea
        }
        .padding(panelPadding)
        .frame(width: panelWidth, alignment: .top)
        // The glass hugs the content and animates its own height with the body.
        // The window grows under it.
        .background(GlassBackground())
        .overlay(panelShape.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        .clipShape(panelShape)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The body below the header: the active screen, cross-fading, with its frame
    /// height animated to the screen's natural height (measured by the hidden
    /// probe). Clipped so the outgoing screen doesn't spill while shorter — and
    /// crucially this clip excludes the header.
    private var bodyArea: some View {
        ZStack(alignment: .top) {
            activeScreen
        }
        .animation(Motion.screen, value: state.tab)
        .animation(Motion.screen, value: state.sessionDraft == nil)
        .frame(height: state.screenHeight > 0 ? state.screenHeight : nil, alignment: .top)
        .clipped()
        .animation(Motion.screen, value: state.screenHeight)
        // Hidden, instantly-swapping copy reports the current screen's natural
        // height (no cross-fade union), without affecting layout.
        .background(alignment: .top) {
            ZStack(alignment: .top) { activeScreen }
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    state.reportScreenHeight(h)
                }
        }
    }

    /// Used twice — once visible (cross-faded) and once hidden to measure.
    @ViewBuilder
    private var activeScreen: some View {
        let move = AnyTransition.asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(Motion.fadeOut))
        if state.tab == .track, state.sessionDraft != nil {
            SessionEditor().transition(move)
        } else if state.tab == .track {
            TrackScreen().transition(move)
        } else {
            StatsScreen().transition(move)
        }
    }
}

// MARK: - header

/// Segmented Track / Stats switch — the blue pill slides between the two
/// (matchedGeometryEffect) — plus copy-summary and reveal-file buttons.
private struct TabBar: View {
    @EnvironmentObject var state: AppState
    @Namespace private var pill
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { t in
                    TabSegment(tab: t, selected: state.tab == t, namespace: pill) {
                        state.tab = t
                    }
                }
            }
            .padding(2)
            .background(shape.fill(.white.opacity(0.06)))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
            .animation(Motion.quick, value: state.tab)

            // Live today total, always in view — the number the app exists for.
            Text(hm(state.todaySeconds))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.running == nil ? .secondary : Color.green)
                .help("Tracked today")

            Spacer(minLength: 0)

            if state.tab == .track {
                Button { withAnimation(Motion.screen) { state.beginAddSession() } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Log a past session")
            }

            CopyButton()
            // Reveal-data-file deliberately lives only in the menu-bar icon's
            // right-click menu — rare maintenance, not panel chrome.
        }
        .padding(.bottom, 8)
    }
}

/// Copies the Stats period's breakdown, and says which period that is — a bare
/// glyph gave no clue whether you were about to copy a day or a month. Confirms
/// with "Copied" for ~1.5s so the click has a visible result (the clipboard is
/// otherwise silent).
private struct CopyButton: View {
    @EnvironmentObject var state: AppState
    private let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Button { state.copySummary() } label: {
            HStack(spacing: 4) {
                Image(systemName: state.justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(state.justCopied ? "Copied" : "Copy \(state.copyPeriod.title.lowercased())")
                    .font(.system(size: 11, weight: .medium))
            }
            // Fixed width, so confirming doesn't resize the button (and with it
            // the header) as the label swaps.
            .frame(width: 82)
            .padding(.vertical, 4)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.justCopied ? Color.green : .secondary)
        .background(shape.fill(.white.opacity(state.justCopied ? 0.10 : 0.05)))
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
        .help("Copy this \(state.copyPeriod.title.lowercased())'s breakdown to the clipboard")
    }
}

private struct TabSegment: View {
    let tab: PanelTab
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 34)
                .padding(.vertical, 6)
                .background {
                    // The single shared pill — matchedGeometryEffect slides it
                    // from one segment to the other when `selected` moves.
                    if selected {
                        shape.fill(pillFill())
                            .matchedGeometryEffect(id: "tabPill", in: namespace)
                    }
                }
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

// MARK: - Track screen

private struct TrackScreen: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            TimerCard()
            if state.lastAutoStop != nil { AutoStopNotice() }
            if !state.projects.isEmpty { GoalsStrip() }
            TotalsRow()
            HistoryList()
        }
        .padding(.top, 10)
    }
}

/// The clock stopping itself is the one state change you didn't ask for, so the
/// panel says it happened rather than leaving you to notice the timer is dark.
private struct AutoStopNotice: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 9))
            Text("Stopped — idle for \(Int(state.idleLimit / 60)) min. Time since your last "
                 + "keystroke wasn't counted.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

/// The one card that matters: what you're working on, the live clock, and the
/// single button that starts or stops it.
private struct TimerCard: View {
    @EnvironmentObject var state: AppState
    @FocusState private var noteFocused: Bool
    @FocusState private var newProjectFocused: Bool

    private var running: Session? { state.running }

    /// The note field edits the running session in place, or the draft when idle,
    /// so retitling mid-session doesn't need a stop/start.
    private var noteBinding: Binding<String> {
        if let r = running {
            return Binding(get: { r.note },
                           set: { state.setRunningNote($0) })
        }
        return Binding(get: { state.draftNote }, set: { state.draftNote = $0 })
    }

    private var activeProjectID: UUID? { state.activeProjectID }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                ProjectChip(selected: activeProjectID)
                // Color the thing you're working on, even mid-session.
                if let id = activeProjectID {
                    Button {
                        withAnimation(Motion.screen) {
                            state.styledProjectID = nil
                            state.showingGoalEditor = false
                            state.showingColorPicker.toggle()
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(state.color(id))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(state.showingColorPicker ? 0.9 : 0.25),
                                              lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Color this project")
                }
                Spacer(minLength: 0)
                // Running: tap the clock to fix when it started (forgot to hit Start).
                Button {
                    if let r = running { withAnimation(Motion.screen) { state.beginEdit(r) } }
                } label: {
                    Text(running == nil ? "0:00" : clock(state.runningElapsed))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(running == nil ? .secondary : .primary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .disabled(running == nil)
                .help(running == nil ? "" : "Edit this session's start time")
            }


            TextField("What are you working on?", text: noteBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($noteFocused)
                .onSubmit { if running == nil { state.toggle() } }

            if state.showingProjectList {
                ProjectList()
            }

            if state.showingColorPicker, let id = state.styleTargetID {
                ColorRow(projectID: id)
            }

            if state.showingGoalEditor, let id = state.styleTargetID {
                GoalRow(projectID: id)
            }

            if state.showingNewProject {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("New project name", text: $state.newProjectName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($newProjectFocused)
                        .onSubmit { commitNewProject() }
                    Button { commitNewProject() } label: {
                        Image(systemName: "return").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06)))
                .onAppear { newProjectFocused = true }
            }

            ActionButton(title: running == nil ? "Start" : "Stop",
                         systemImage: running == nil ? "play.fill" : "stop.fill",
                         tint: running == nil ? .blue : .red,
                         active: true) {
                noteFocused = false
                withAnimation(Motion.quick) { state.toggle() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(running == nil ? 0.05 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(running == nil ? .white.opacity(0.10) : Color.green.opacity(0.35),
                          lineWidth: 0.8))
        .animation(Motion.quick, value: running?.id)
        .onExitCommand { noteFocused = false; newProjectFocused = false }
    }

    private func commitNewProject() {
        state.addProject(state.newProjectName)
        state.newProjectName = ""
        withAnimation(Motion.screen) { state.showingNewProject = false }
    }
}

/// The color picker: the eight built-in colors as tappable swatches, plus the
/// system color panel for anything else. Applies live — the dot, the history rows,
/// and the Stats bars all recolor as you pick.
private struct ColorRow: View {
    @EnvironmentObject var state: AppState
    let projectID: UUID

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(projectPalette.enumerated()), id: \.offset) { i, color in
                let selected = state.paletteIndex(projectID) == i
                Button {
                    state.setPaletteColor(projectID, index: i)
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.18),
                                                       lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Use this color")
            }

            Divider().frame(height: 14).opacity(0.3)

            // The real macOS color panel — wheel, sliders, hex, eyedropper — opened
            // as its own window. (SwiftUI's ColorPicker would embed an NSColorWell
            // in here, which jitters during the panel's animations.)
            Button {
                ColorPanelBridge.shared.show(initial: state.color(projectID)) { c in
                    state.setCustomColor(projectID, c)
                }
            } label: {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Custom color…")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.06)))
        // Don't leave the color panel writing into a row that's gone.
        .onDisappear { ColorPanelBridge.shared.detach() }
    }
}

/// Colored-dot chip that expands the project list inline. A plain SwiftUI button,
/// not a `Menu`: a Menu is backed by a real AppKit view, which sits inside the
/// hosting view and doesn't follow SwiftUI's geometry group — whenever the panel
/// animated geometry (it used to scale on open), its frame landed a frame behind
/// everything around it, which is what made the dot and project name jitter.
///
/// While a session runs, picking another project switches to it: the session
/// ends and a new one starts (see AppState.switchProject).
private struct ProjectChip: View {
    @EnvironmentObject var state: AppState
    let selected: UUID?

    var body: some View {
        Button {
            withAnimation(Motion.screen) {
                state.showingProjectList.toggle()
                if state.showingProjectList {
                    state.showingColorPicker = false
                    state.showingGoalEditor = false
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(state.color(selected)).frame(width: 8, height: 8)
                Text(state.name(selected))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(state.showingProjectList ? 180 : 0))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(state.running == nil ? "Choose project" : "Switch project (starts a new session)")
    }
}

/// The inline project list the chip expands into: pick one, add one, recolor or
/// archive one — all plain SwiftUI rows, so nothing here can jitter.
private struct ProjectList: View {
    @EnvironmentObject var state: AppState

    private var selected: UUID? { state.activeProjectID }

    private func choose(_ id: UUID?) {
        state.switchProject(to: id)
        withAnimation(Motion.screen) { state.showingProjectList = false }
    }

    private func style(_ id: UUID, goal: Bool) {
        state.styledProjectID = id
        withAnimation(Motion.screen) {
            state.showingProjectList = false
            state.showingColorPicker = !goal
            state.showingGoalEditor = goal
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Row(name: "Unlabeled", color: .secondary, selected: selected == nil, goal: nil,
                onPick: { choose(nil) }, onColor: nil, onGoal: nil, onArchive: nil)

            ForEach(state.projects) { p in
                Row(name: p.name, color: p.color, selected: p.id == selected,
                    goal: p.goalMinutes.map { "\(hm(TimeInterval($0 * 60)))/\(p.goalPeriod == .week ? "wk" : "day")" },
                    onPick: { choose(p.id) },
                    onColor: { style(p.id, goal: false) },
                    onGoal: { style(p.id, goal: true) },
                    onArchive: { withAnimation(Motion.screen) { state.archive(p.id) } })
            }

            Divider().opacity(0.2).padding(.vertical, 2)

            Button {
                withAnimation(Motion.screen) {
                    state.showingProjectList = false
                    state.showingNewProject = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 11))
                    Text("New Project…").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5).padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.06)))

    }

    private struct Row: View {
        let name: String
        let color: Color
        let selected: Bool
        /// "3h/day", shown until hover swaps in the row's actions.
        let goal: String?
        let onPick: () -> Void
        let onColor: (() -> Void)?
        let onGoal: (() -> Void)?
        let onArchive: (() -> Void)?
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                Button(action: onPick) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(selected ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Reserve the width so hovering never shifts the name.
                HStack(spacing: 4) {
                    if let onColor {
                        Button(action: onColor) {
                            Image(systemName: "paintpalette").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Color this project")
                    }
                    if let onGoal {
                        Button(action: onGoal) {
                            Image(systemName: "target").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Goal")
                    }
                    if let onArchive {
                        Button(action: onArchive) {
                            Image(systemName: "archivebox").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Archive (keeps its history)")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
                .opacity(hovering && onColor != nil ? 1 : 0)
                .overlay(alignment: .trailing) {
                    if let goal, !hovering {
                        Text(goal).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
        }
    }
}

/// Day / week / month at a glance — three tiles that always agree with Stats.
private struct TotalsRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Tile(label: "Today", value: hm(state.todaySeconds), accent: .blue)
            Tile(label: "Week", value: hm(state.weekSeconds), accent: .teal)
            Tile(label: "Month", value: hm(state.monthSeconds), accent: .purple)
        }
    }

    private struct Tile: View {
        let label: String
        let value: String
        let accent: Color

        var body: some View {
            VStack(spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05)))
        }
    }
}

/// Recent sessions, newest first, grouped by day with that day's total.
private struct HistoryList: View {
    @EnvironmentObject var state: AppState
    private let scrollCap: CGFloat = 260   // scroll past this; below it the panel hugs

    var body: some View {
        let days = state.recentDays
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            if days.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                SectionLabel(text: day.title, accent: .secondary,
                                             trailing: hm(day.seconds))
                                ForEach(day.items) { g in SessionRow(group: g) }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                        state.historyInnerHeight = $0
                    }
                }
                .frame(height: min(state.historyInnerHeight, scrollCap))
            }
        }
    }
}

/// One history row. It may stand for several sessions with the same project and
/// note — see SessionGroup. When it does, the time is their sum, the range is
/// the whole span, and a ×N chip says how many taps are behind it.
private struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let group: SessionGroup
    @State private var hovering = false

    private var session: Session { group.sessions[0] }

    /// Hovering a merged row lists what it folded, so the detail is still there.
    private var breakdown: String {
        guard group.count > 1 else { return "Start a new session with this label" }
        return group.sessions.reversed()
            .map { "\(timeRange($0))   \(hm($0.duration(now: state.now)))" }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(state.color(group.projectID))
                .frame(width: 7, height: 7)
                .offset(y: -1)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.note.isEmpty ? state.name(group.projectID) : group.note)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if !group.note.isEmpty {
                        Text(state.name(group.projectID))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("·").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(timeSpan(group))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.10)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                // Restart this exact label — the fastest path back into a task.
                Button { state.resume(session) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Start a new session with this label")
            }

            Text(hm(group.seconds(now: state.now)))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.04)))
        .onHover { hovering = $0 }
        .help(breakdown)
        .contentShape(Rectangle())
        // A single session opens its editor; a merged row picks one from the
        // context menu.
        .onTapGesture {
            if group.count == 1 { withAnimation(Motion.screen) { state.beginEdit(session) } }
        }
        .contextMenu {
            Button { state.resume(session) } label: {
                Label("Start again", systemImage: "arrow.clockwise")
            }
            if group.count == 1 {
                Button { withAnimation(Motion.screen) { state.beginEdit(session) } } label: {
                    Label("Edit…", systemImage: "pencil")
                }
            } else {
                Menu("Edit") {
                    ForEach(group.sessions.reversed()) { s in
                        Button("\(timeRange(s))  ·  \(hm(s.duration(now: state.now)))") {
                            withAnimation(Motion.screen) { state.beginEdit(s) }
                        }
                    }
                }
            }
            Menu("Project") {
                Button("Unlabeled") { state.setProject(nil, for: group) }
                ForEach(state.projects) { p in
                    Button(p.name) { state.setProject(p.id, for: group) }
                }
            }
            Divider()
            Button(role: .destructive) { state.delete(group) } label: {
                Label(group.count > 1 ? "Delete \(group.count) sessions" : "Delete",
                      systemImage: "trash")
            }
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 24)).foregroundStyle(.secondary)
            Text("Nothing tracked yet").font(.system(size: 12, weight: .medium))
            Text("Hit Start when you begin working")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

// MARK: - Stats screen

private struct StatsScreen: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            PeriodPicker()

            VStack(spacing: 2) {
                Text(state.period.currentLabel.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(hm(state.seconds(for: state.period)))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
            }

            TrendChart(buckets: state.trend)

            Breakdown(totals: state.breakdown, period: state.period)
        }
        .padding(.top, 12)
    }
}

private struct PeriodPicker: View {
    @EnvironmentObject var state: AppState
    @Namespace private var pill
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { p in
                Button {
                    withAnimation(Motion.quick) { state.period = p }
                } label: {
                    Text(p.title)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if state.period == p {
                                shape.fill(pillFill())
                                    .matchedGeometryEffect(id: "periodPill", in: pill)
                            }
                        }
                        .foregroundStyle(state.period == p ? Color.white : Color.secondary)
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(shape.fill(.white.opacity(0.06)))
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
    }
}

/// The last N periods as bars, so a single number gets context — is today light
/// or heavy for you? The current bucket is highlighted.
private struct TrendChart: View {
    let buckets: [TrendBucket]
    private let height: CGFloat = 56

    private var peak: TimeInterval { max(buckets.map(\.seconds).max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(buckets) { b in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(b.isCurrent ? AnyShapeStyle(Color.blue)
                                              : AnyShapeStyle(Color.white.opacity(0.18)))
                            // 2pt floor so an empty bucket still reads as a slot.
                            .frame(height: max(2, height * CGFloat(b.seconds / peak)))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(b.label) — \(hm(b.seconds))")
                }
            }
            .frame(height: height)

            HStack(spacing: 5) {
                ForEach(buckets) { b in
                    Text(b.label)
                        .font(.system(size: 9))
                        .foregroundStyle(b.isCurrent ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            }
        }
        .animation(Motion.quick, value: buckets.map(\.seconds))
    }
}

/// What exactly you worked on this period: project, share bar, total.
private struct Breakdown: View {
    @EnvironmentObject var state: AppState
    let totals: [ProjectTotal]
    let period: Period

    /// "of 3h" when this project's goal is for the period on screen.
    private func goalText(_ t: ProjectTotal) -> String? {
        guard let p = state.data.projects.first(where: { $0.id.uuidString == t.id }),
              let m = p.goalMinutes, p.goalPeriod == period else { return nil }
        return "of \(hm(TimeInterval(m * 60)))"
    }

    private var sum: TimeInterval { max(totals.reduce(0) { $0 + $1.seconds }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.35)
            SectionLabel(text: "By project")
                .padding(.top, 4)

            if totals.isEmpty {
                Text("Nothing tracked in this period")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ForEach(totals) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(t.color).frame(width: 7, height: 7)
                            Text(t.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(hm(t.seconds))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let goal = goalText(t) {
                                Text(goal).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text("\(Int((t.seconds / sum * 100).rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.07))
                                Capsule().fill(t.color.opacity(0.85))
                                    .frame(width: max(3, geo.size.width * CGFloat(t.seconds / sum)))
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.bottom, 2)
    }
}
