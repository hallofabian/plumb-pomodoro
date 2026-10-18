import AppKit
import SwiftUI

/// `Plumb --render-snapshots <dir>` draws each screen offscreen to PNG files,
/// filled with invented demo data. Used for the README screenshots and to
/// review the UI without screen-recording permission.
///
/// Requires PLUMB_DATA_DIR pointing at an empty scratch folder, so it can never
/// touch real data. For English dates: add `-AppleLocale en_GB -AppleLanguages '(en)'`.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        guard ProcessInfo.processInfo.environment["PLUMB_DATA_DIR"] != nil else {
            FileHandle.standardError.write(Data("Set PLUMB_DATA_DIR to a scratch folder first.\n".utf8))
            exit(1)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let services = Services.shared
        let demo = DemoData.populate(services.store)

        // Show the sync mark in the panel; the folder lives inside the scratch data dir.
        services.store.settings.syncFolderPath = services.store.directory.appendingPathComponent("sync-demo").path
        services.sync.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        // Panel: a work interval on the thesis, 31 minutes in.
        let engine = services.engine
        engine.idleSeconds = { 0 }
        engine.select(taskID: demo.thesis)
        engine.start()
        let started = Date()
        engine.clock = { started.addingTimeInterval(31 * 60 + 20) }
        engine.tick()

        let panel = { AnyView(TimerPopover(services: services).overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))) }
        var screens: [(String, () -> AnyView, NSSize?)] = [
            ("panel", panel, nil),
            ("today", { AnyView(TasksView(services: services)) }, WindowKind.tasks.size),
            ("task-forecast", { AnyView(TasksView(services: services, selection: demo.thesis)) }, NSSize(width: 820, height: 760)),
            ("reports", { AnyView(ReportsView(store: services.store, period: .thisMonth)) }, NSSize(width: 860, height: 900)),
        ]
        screens += SettingsTab.allCases.filter { $0 != .integrations && $0 != .sync }.map { tab in
            ("settings-\(tab.rawValue)", { AnyView(SettingsView(services: services, tab: tab)) }, WindowKind.settings.size)
        }
        for (name, view, size) in screens { capture(name, view, size, into: dir) }

        // The same panel after stepping away for 12 minutes.
        engine.idleSeconds = { 12 * 60 }
        engine.tick()
        capture("panel-away", panel, nil, into: dir)

        // The break card once that interval is ended.
        engine.idleSeconds = { 0 }
        engine.resolveAway(.end)
        capture("break-card", { AnyView(BreakCard(services: services, showControls: true) {}) }, NSSize(width: 1200, height: 640), into: dir)
    }

    /// Renders light and dark variants; a nil size uses the view's own fitting size.
    private static func capture(_ name: String, _ view: () -> AnyView, _ size: NSSize?, into dir: URL) {
        for dark in [false, true] {
            let content = view().background(TE.canvas)
            let host = NSHostingView(rootView: size.map { AnyView(content.frame(width: $0.width, height: $0.height)) } ?? AnyView(content))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
}

/// Invented sample data: a few weeks of study work, estimates that run over,
/// and a morning already logged. Deterministic apart from "today".
@MainActor
enum DemoData {
    struct IDs {
        var thesis: UUID
    }

    static func populate(_ store: Store) -> IDs {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = Date()
        var rng = SplitMix64(seed: 42)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func roll(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }

        // Weekends are rest days; today always has a goal so the screenshots show progress.
        var targets = [0, 8, 8, 8, 8, 8, 0]
        targets[cal.component(.weekday, from: today) - 1] = 8
        store.settings.weekdayTargets = targets
        store.settings.ambientSource = "noise.brown"
        let study = WorkType.example5010.id

        func task(_ title: String, due: Int? = nil, type: UUID? = nil, note: String = "") -> UUID {
            var t = store.addTask(title: title)
            t.dueDate = due.map(day)
            t.workTypeID = type
            t.note = note
            store.update(t)
            return t.id
        }
        func setEstimate(_ id: UUID, _ value: Int?) {
            guard var t = store.task(id) else { return }
            t.estimatedIntervals = value
            store.update(t)
        }

        // Open work, in list order.
        let thesis = task("Thesis: chapter 3", due: 24, type: study, note: "Methods and first results. Supervisor meeting on the 12th.")
        let exam = task("Statistics exam prep", due: 9)
        let reading = task("Read: Kahneman ch. 8–10", due: 0)
        let portfolio = task("Portfolio website")
        let inbox = task("Email & admin")

        // Finished tasks whose estimates ran over; they drive the calibration.
        let finished: [(String, Int, Int, Int)] = [
            ("Literature review", 20, 27, -52), ("Survey design", 10, 13, -38),
            ("Grant proposal draft", 15, 18, -27), ("Data cleaning", 8, 14, -16),
        ]
        for (title, estimate, actual, completedOffset) in finished {
            let id = task(title)
            setEstimate(id, estimate)
            for i in 0..<actual {
                let start = day(completedOffset - actual / 2 + i / 2).addingTimeInterval(Double(7 * 3600 + (i % 2) * 3600))
                store.addInterval(FocusInterval(taskID: id, phase: .work, start: start, duration: 1500, outcome: .completed))
            }
            if var t = store.task(id) {
                t.completedAt = day(completedOffset).addingTimeInterval(17 * 3600)
                store.update(t)
            }
        }

        // Eight weeks of history before today. One weaker weekday nine days ago
        // ends the streak there; the thesis took over in the last five weeks.
        let missedDay = ((-12)...(-8)).first { store.settings.target(on: day($0)) > 0 } ?? -9
        for offset in (-56)...(-1) {
            let date = day(offset)
            let target = store.settings.target(on: date)
            // One spare interval a day, so an occasional skip does not break the streak.
            let count = target == 0 ? roll(2) : (offset == missedDay ? 5 : (offset < -35 ? 5 : target + 1 + roll(2)))
            var clock = date.addingTimeInterval(8.5 * 3600 + Double(roll(4)) * 900)
            for i in 0..<count {
                let pick = roll(20)
                let taskID: UUID?
                if offset >= -35, pick < 9 { taskID = thesis }
                else if offset >= -21, pick < 14 { taskID = exam }
                else if offset >= -3, pick < 16 { taskID = reading }
                else if pick < 17 { taskID = portfolio }
                else if pick < 19 { taskID = inbox }
                else { taskID = nil }
                let minutes = taskID == thesis ? 50.0 : 25.0
                let skipped = roll(16) == 0
                let length = skipped ? minutes * 60 * 0.4 : minutes * 60
                store.addInterval(FocusInterval(taskID: taskID, phase: .work, start: clock, duration: length,
                                                outcome: skipped ? .skipped : .completed))
                clock = clock.addingTimeInterval(length)
                let rest = taskID == thesis ? 600.0 : (i % 4 == 3 ? 900 : 300)
                store.addInterval(FocusInterval(taskID: taskID, phase: i % 4 == 3 ? .longBreak : .shortBreak,
                                                start: clock, duration: rest, outcome: .completed))
                clock = clock.addingTimeInterval(rest + Double(roll(3)) * 300)
            }
        }

        // Estimates relative to what is done, so the forecast has work left to predict.
        setEstimate(thesis, store.completedWorkCount(for: thesis) + 40)
        setEstimate(exam, store.completedWorkCount(for: exam) + 10)
        setEstimate(reading, 6)
        setEstimate(portfolio, store.completedWorkCount(for: portfolio) + 8)

        // This morning, with notes.
        let morning: [(UUID?, Double, String?)] = [
            (thesis, 50, "outlined section 3.2"), (thesis, 50, "wrote ~600 words on sampling"),
            (reading, 25, "ch. 8 done, notes in Zotero"), (exam, 25, "regression exercises 1–6"),
        ]
        var clock = today.addingTimeInterval(8.5 * 3600)
        for (taskID, minutes, note) in morning {
            let end = clock.addingTimeInterval(minutes * 60)
            guard end < now.addingTimeInterval(-40 * 60) else { break }
            store.addInterval(FocusInterval(taskID: taskID, phase: .work, start: clock, duration: minutes * 60,
                                            outcome: .completed, note: note))
            store.addInterval(FocusInterval(taskID: taskID, phase: .shortBreak, start: end,
                                            duration: minutes == 50 ? 600 : 300, outcome: .completed))
            clock = end.addingTimeInterval(minutes == 50 ? 900 : 600)
        }
        store.clearUndo()
        store.saveNow()
        return IDs(thesis: thesis)
    }
}
