import AppKit
import SwiftUI

/// `Plumb --render-snapshots <dir>` draws each screen offscreen to PNG files.
/// Used to review the UI without screen-recording permission. Run it with
/// PLUMB_DATA_DIR pointing at a scratch folder so real data stays untouched.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let services = Services.shared
        if services.store.intervals.isEmpty {
            _ = try? BeFocusedImport.importFile(BeFocusedImport.defaultFile, into: services.store, importSettings: true)
        }
        addExampleForecastData(services.store)
        if let dir = ProcessInfo.processInfo.environment["PLUMB_DATA_DIR"] {
            // Show the sync indicator, syncing into a folder inside the scratch data dir.
            services.store.settings.syncFolderPath = dir + "/sync-demo"
            services.sync.start()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        if let task = services.store.activeTasks.first { services.engine.select(taskID: task.id) }

        let screens: [(String, AnyView, NSSize)] = [
            ("popover", AnyView(TimerPopover(services: services).overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))), NSSize(width: 320, height: 560)),
            ("tasks", AnyView(TasksView(services: services)), WindowKind.tasks.size),
            ("task-detail", AnyView(TasksView(services: services, selection: services.store.activeTasks.first?.id)), WindowKind.tasks.size),
            ("reports", AnyView(ReportsView(store: services.store, period: .all)), WindowKind.reports.size),
        ] + SettingsTab.allCases.map { tab in
            ("settings-\(tab.rawValue)", AnyView(SettingsView(services: services, tab: tab)), WindowKind.settings.size)
        }
        for (name, view, size) in screens {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
        }
    }
}

extension Snapshots {
    /// Example estimates and recent intervals so the forecast has something to show.
    /// Only for the snapshot data folder; never runs against real data.
    static func addExampleForecastData(_ store: Store) {
        guard ProcessInfo.processInfo.environment["PLUMB_DATA_DIR"] != nil,
              var task = store.activeTasks.first, task.estimatedIntervals == nil else { return }
        for (done, ratio) in zip(store.completedTasks.prefix(4), [1.2, 1.6, 0.9, 1.4]) {
            var t = done
            t.estimatedIntervals = max(1, Int((Double(store.completedWorkCount(for: t.id)) / ratio).rounded()))
            store.update(t)
        }
        task.estimatedIntervals = 60
        store.update(task)
        let cal = Calendar.current
        for (weeksAgo, count) in [(5, 3), (4, 6), (3, 2), (2, 7), (1, 5), (0, 4)] {
            for i in 0..<count {
                let day = cal.date(byAdding: .day, value: -(weeksAgo * 7) - i % 5, to: cal.startOfDay(for: Date()))!
                store.addInterval(FocusInterval(taskID: task.id, phase: .work, start: day.addingTimeInterval(Double(9 + i) * 3600),
                                                duration: 3000, outcome: .completed, note: i == 0 ? "drafted a section" : nil))
            }
        }
    }
}
