import AppKit
import UniformTypeIdentifiers

@MainActor
enum CSVExport {
    static func run(store: Store) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Plumb \(Date().formatted(.iso8601.year().month().day())).csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(store: store).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func csv(store: Store) -> String {
        let date = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let time = Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: false)
        var rows = ["date,start,end,task,phase,outcome,minutes,work_type"]
        for i in store.intervals.sorted(by: { $0.start < $1.start }) {
            let task = store.task(i.taskID)
            let end = i.start.addingTimeInterval(i.duration)
            rows.append([
                i.start.formatted(date), i.start.formatted(time), end.formatted(time),
                store.title(for: i.taskID), i.phase.rawValue, i.outcome.rawValue,
                String(format: "%.2f", i.duration / 60), store.workType(task?.workTypeID)?.name ?? "",
            ].map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\n".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Imports tasks, interval history and timer settings from Be Focused's local data file.
///
/// File format (observed in Be Focused Pro 2.6): a binary plist holding a tree of
/// dictionaries with `className`, `id` and `children`. `PMTask` nodes are tasks,
/// `PMPomodoro` nodes are intervals (Unix timestamps, `completionState` 3 = completed,
/// 4 = skipped), `PMAppSettings` holds durations in minutes.
@MainActor
enum BeFocusedImport {
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.xwavesoft.pomodoromac/Data/Documents/SANDBOX_ITEM_v_6.plist")

    struct Summary {
        var tasks = 0
        var intervals = 0
        var settingsImported = false
    }

    static func runInteractive(store: Store) {
        var url = defaultFile
        if !FileManager.default.isReadableFile(atPath: url.path) {
            let panel = NSOpenPanel()
            panel.message = L("Choose Be Focused's data file (SANDBOX_ITEM_v_6.plist)")
            panel.directoryURL = defaultFile.deletingLastPathComponent()
            panel.allowedContentTypes = [.propertyList]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        let alert = NSAlert()
        do {
            let summary = try importFile(url, into: store, importSettings: true)
            alert.messageText = L("Import finished")
            alert.informativeText = L("%@ tasks and %@ intervals imported", "\(summary.tasks)", "\(summary.intervals)")
                + (summary.settingsImported ? L(", timer durations taken over.") : ".")
                + L(" Importing again is safe; existing records are updated, not duplicated.")
        } catch {
            alert.messageText = L("Import failed")
            alert.informativeText = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func importFile(_ url: URL, into store: Store, importSettings: Bool) throws -> Summary {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (library, durations, target) = parse(root)
        var summary = Summary(tasks: library.tasks.count, intervals: library.intervals.count)
        store.merge(library, isLocalChange: true)
        if importSettings, let durations {
            store.settings.durations = durations
            if let target { store.settings.dailyTarget = target }
            summary.settingsImported = true
        }
        return summary
    }

    static func parse(_ root: [String: Any]) -> (Library, Durations?, Int?) {
        var nodes: [String: [[String: Any]]] = [:]
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let cls = dict["className"] as? String { nodes[cls, default: []].append(dict) }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)

        var durations: Durations?
        var target: Int?
        if let s = nodes["PMAppSettings"]?.first {
            var d = Durations()
            d.work = s["pomodoroLenght"] as? Int ?? d.work
            d.shortBreak = s["restTime"] as? Int ?? d.shortBreak
            d.longBreak = s["bigRestTime"] as? Int ?? d.longBreak
            d.longBreakAfter = s["pomodorosInPeriodCount"] as? Int ?? d.longBreakAfter
            durations = d
            target = s["pomodorosPerDay"] as? Int
        }
        let longBreakSeconds = Double((durations ?? Durations()).longBreak * 60)

        // Import timestamps are fixed so re-importing does not override later edits.
        let importStamp = Date(timeIntervalSince1970: 0)
        var lib = Library()
        for (index, t) in (nodes["PMTask"] ?? []).enumerated() {
            guard let id = (t["id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            let completed = (t["completionState"] as? Int) == 3
            let completedAt = (t["completionTime"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let created = (t["creationTime"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } ?? importStamp
            let due = (t["dueDate"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let estimate = (t["expectedIntervals"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            lib.tasks.append(FocusTask(
                id: id, title: t["title"] as? String ?? L("Untitled"), note: t["note"] as? String ?? "",
                estimatedIntervals: estimate, dueDate: due,
                completedAt: completed ? (completedAt ?? created) : nil,
                createdAt: created, sortIndex: Double(index), updatedAt: importStamp
            ))
        }
        let taskIDs = Set(lib.tasks.map(\.id))
        for p in nodes["PMPomodoro"] ?? [] {
            guard let id = (p["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let start = p["startTimeStamp"] as? Double, start > 0,
                  let state = p["completionState"] as? Int, state == 3 || state == 4 else { continue }
            let duration = p["commonTimeInterval"] as? Double ?? 0
            let isRest = p["isRest"] as? Bool ?? false
            let taskID = (p["parentTaskID"] as? String).flatMap(UUID.init(uuidString:)).flatMap { taskIDs.contains($0) ? $0 : nil }
            lib.intervals.append(FocusInterval(
                id: id, taskID: taskID,
                phase: isRest ? (duration >= longBreakSeconds ? .longBreak : .shortBreak) : .work,
                start: Date(timeIntervalSince1970: start), duration: duration,
                outcome: state == 3 ? .completed : .skipped, updatedAt: importStamp
            ))
        }
        return (lib, durations, target)
    }
}
