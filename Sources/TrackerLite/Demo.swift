// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import Foundation

/// `--demo`: made-up projects and a week of sessions for screenshots. The real
/// data file (and iCloud) is never read or written while it's on.
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("--demo")

    static var data: TrackerData {
        let cal = Calendar.current
        var d = TrackerData()
        func project(_ name: String, _ color: Int, goal: Int? = nil, _ period: Period? = nil) -> Project {
            var p = Project(name: name, colorIndex: color)
            p.goalMinutes = goal; p.goalPeriod = period
            return p
        }
        let thesis = project("Thesis", 0, goal: 120, .day)
        let ml = project("Machine Learning", 1, goal: 8 * 60, .week)
        let reading = project("Reading", 2, goal: 30, .day)
        let side = project("Side project", 3)
        d.projects = [thesis, ml, reading, side]

        // (days ago, start hour, minutes, project, note)
        let plan: [(Int, Double, Int, Project, String)] = [
            (6, 9.5, 110, thesis, "Lit review"), (6, 14, 75, ml, "Problem set"), (6, 21, 35, reading, ""),
            (5, 10, 140, thesis, "Draft methods"), (5, 16, 50, side, "Menu-bar app"),
            (4, 9, 95, ml, "Lecture notes"), (4, 13, 120, thesis, "Experiments"), (4, 22, 30, reading, ""),
            (3, 11, 60, ml, "Problem set"), (3, 15, 150, thesis, "Figures"),
            (2, 9.5, 130, thesis, "Writing"), (2, 14.5, 90, ml, "Project"), (2, 20, 40, reading, ""),
            (1, 10, 100, thesis, "Edits"), (1, 13.5, 120, ml, "Project"), (1, 19, 60, side, "README"),
            (1, 22, 25, reading, ""),
        ]
        let today = cal.startOfDay(for: Date())
        for (ago, hour, minutes, p, note) in plan {
            let day = cal.date(byAdding: .day, value: -ago, to: today)!
            let start = day.addingTimeInterval(hour * 3600)
            d.sessions.append(Session(projectID: p.id, note: note, start: start,
                                      end: start.addingTimeInterval(Double(minutes) * 60)))
        }
        // Today: one finished session, one running.
        let now = Date()
        d.sessions.append(Session(projectID: reading.id, note: "", start: now.addingTimeInterval(-3 * 3600),
                                  end: now.addingTimeInterval(-3 * 3600 + 20 * 60)))
        d.sessions.append(Session(projectID: thesis.id, note: "Results section",
                                  start: now.addingTimeInterval(-(75 * 60 + 12)), end: nil))
        return d
    }
}
