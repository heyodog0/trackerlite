// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI

/// Fix a session's times, project or note — or log one you never started the
/// clock for. Replaces the Track screen while open, like RemindLite's editor.
struct SessionEditor: View {
    @EnvironmentObject var state: AppState
    @State private var pickingDay = false
    private let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
    private var cal: Calendar { .current }

    private var draft: SessionDraft { state.sessionDraft ?? .init(projectID: nil, note: "", start: .now, end: .now, isRunning: false) }
    private var isNew: Bool { draft.id == nil }

    private func update(_ change: (inout SessionDraft) -> Void) {
        guard var d = state.sessionDraft else { return }
        change(&d)
        // Keep the end's clock time, on the start's day — or the next day when
        // that would put it before the start (a session across midnight).
        if !d.isRunning {
            let t = cal.dateComponents([.hour, .minute, .second], from: d.end)
            var end = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0,
                               of: d.start) ?? d.end
            if end <= d.start { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
            d.end = end
        }
        state.sessionDraft = d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            labelCard
            timesCard
            if state.overlaps(draft) > 0 {
                Label("Overlaps \(state.overlaps(draft) == 1 ? "another session" : "\(state.overlaps(draft)) sessions") — that time would count twice",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if !isNew {
                Button { withAnimation(Motion.screen) { state.deleteSessionDraft() } } label: {
                    Label("Delete Session", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .background(card.fill(.red.opacity(0.10)))
            }
        }
        .padding(.top, 10)
    }

    private var header: some View {
        ZStack {
            Text(isNew ? "Log Session" : "Edit Session").font(.system(size: 13, weight: .semibold))
            HStack {
                Button { withAnimation(Motion.screen) { state.sessionDraft = nil } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 12))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                let ok = draft.isValid(now: state.now)
                Button { withAnimation(Motion.screen) { state.saveSessionDraft() } } label: {
                    Text(isNew ? "Add" : "Save")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(height: 24).padding(.horizontal, 14)
                        .background(Capsule().fill(Color.blue.opacity(ok ? 0.85 : 0.3)))
                }
                .buttonStyle(.plain).disabled(!ok)
            }
        }
    }

    private var labelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("Unlabeled") { update { $0.projectID = nil } }
                ForEach(state.projects) { p in
                    Button(p.name) { update { $0.projectID = p.id } }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(state.color(draft.projectID)).frame(width: 8, height: 8)
                    Text(state.name(draft.projectID)).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            // .button + .plain keeps the label a SwiftUI view (borderless
            // flattens it to tinted text and drops the dot).
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            TextField("What were you working on?", text: Binding(
                get: { draft.note }, set: { v in update { $0.note = v } }))
                .textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.fill(.white.opacity(0.05)))
    }

    private var timesCard: some View {
        VStack(spacing: 7) {
            row("Date", "calendar") {
                Button { pickingDay = true } label: {
                    Text(draft.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickingDay, arrowEdge: .bottom) {
                    DatePicker("", selection: Binding(get: { draft.start }, set: moveToDay),
                               in: ...Date(), displayedComponents: [.date])
                        .datePickerStyle(.graphical).labelsHidden()
                        .padding(10)
                }
            }
            row("Started", "play") {
                TimeMenu(date: Binding(get: { draft.start }, set: { v in update { $0.start = v } }))
            }
            row("Ended", "stop") {
                if draft.isRunning {
                    Text("Still running").font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    HStack(spacing: 4) {
                        if !cal.isDate(draft.end, inSameDayAs: draft.start) {
                            Text("next day").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        TimeMenu(date: Binding(get: { draft.end }, set: { v in update { $0.end = v } }))
                    }
                }
            }
            Divider().opacity(0.2)
            HStack {
                Text("Length").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(hm(draft.isRunning ? state.now.timeIntervalSince(draft.start) : draft.duration))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
        }
        .padding(10)
        .background(card.fill(.white.opacity(0.05)))
    }

    /// A new day keeps the start and end clock times.
    private func moveToDay(_ day: Date) {
        pickingDay = false
        update { d in
            let t = cal.dateComponents([.hour, .minute, .second], from: d.start)
            let length = d.duration
            d.start = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0,
                               of: day) ?? d.start
            if !d.isRunning { d.end = d.start.addingTimeInterval(length) }
        }
    }

    private func row<Trailing: View>(_ title: String, _ icon: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.system(size: 12))
            Spacer(minLength: 4)
            trailing()
        }
        .frame(minHeight: 22)
    }
}

/// One compact time menu ("1:30 PM"): pick an hour, then the minute.
struct TimeMenu: View {
    @Binding var date: Date
    private var cal: Calendar { .current }

    var body: some View {
        Menu {
            ForEach(0..<24, id: \.self) { h in
                Menu(label(h, 0, hourOnly: true)) {
                    ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) { m in
                        Button(label(h, m)) { set(h, m) }
                    }
                }
            }
        } label: {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func label(_ h: Int, _ m: Int, hourOnly: Bool = false) -> String {
        let d = cal.date(bySettingHour: h, minute: m, second: 0, of: date) ?? date
        return hourOnly ? d.formatted(.dateTime.hour()) : d.formatted(date: .omitted, time: .shortened)
    }

    private func set(_ h: Int, _ m: Int) {
        if let d = cal.date(bySettingHour: h, minute: m, second: 0, of: date) { date = d }
    }
}
