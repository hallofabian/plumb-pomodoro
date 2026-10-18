import Foundation

struct CommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The one place that turns named commands into actions. The plumb:// URL
/// scheme, the control socket (CLI and MCP server) and tests all go through here.
/// Arguments and results are JSON-compatible dictionaries.
@MainActor
final class CommandCenter {
    private let store: Store
    private let engine: TimerEngine
    private let completeTask: (UUID) -> Void

    init(store: Store, engine: TimerEngine, completeTask: ((UUID) -> Void)? = nil) {
        self.store = store
        self.engine = engine
        self.completeTask = completeTask ?? { store.setCompleted($0, true) }
    }

    static let commands = [
        "status", "start", "pause", "toggle", "skip", "stop", "extend", "list_tasks", "add_task",
        "complete_task", "select_task", "add_note", "add_interval", "report", "forecast", "set_goal",
    ]

    func run(_ command: String, _ args: [String: Any] = [:]) throws -> Any {
        switch command {
        case "status":
            return status()
        case "start":
            if let ref = args["task"] { engine.select(taskID: try resolveTask(ref)) }
            if engine.awaySince != nil { engine.resolveAway(.drop) } else { engine.start() }
            return status()
        case "pause":
            engine.pause()
            return status()
        case "toggle":
            engine.toggle()
            return status()
        case "skip":
            engine.skip()
            return status()
        case "stop":
            engine.stop()
            return status()
        case "extend":
            let minutes = int(args["minutes"]) ?? store.settings.extendMinutes
            if engine.phase.isBreak {
                engine.keepWorking(minutes: minutes)
            } else {
                guard engine.canExtend else { throw CommandError("Nothing to extend: start a work interval first.") }
                engine.extend(minutes: minutes)
            }
            return status()
        case "list_tasks":
            let includeCompleted = bool(args["include_completed"]) ?? false
            let tasks = store.activeTasks + (includeCompleted ? store.completedTasks : [])
            return tasks.map(describe)
        case "add_task":
            guard let title = string(args["title"])?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
                throw CommandError("add_task needs a title.")
            }
            var task = store.addTask(title: title)
            task.estimatedIntervals = int(args["estimate"]).flatMap { $0 > 0 ? $0 : nil }
            if let due = string(args["due"]) {
                guard let date = Self.day.date(from: due) else { throw CommandError("due must be YYYY-MM-DD.") }
                task.dueDate = date
            }
            if let name = string(args["work_type"]) {
                guard let type = store.workTypes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw CommandError("No work type named “\(name)”. Known: \(store.workTypes.map(\.name).joined(separator: ", ")).")
                }
                task.workTypeID = type.id
            }
            store.update(task)
            if bool(args["select"]) == true { engine.select(taskID: task.id) }
            return describe(store.task(task.id) ?? task)
        case "complete_task":
            guard let id = try resolveTask(args["task"] ?? "") else { throw CommandError("The task “other” cannot be completed.") }
            completeTask(id)
            return describe(store.task(id)!)
        case "select_task":
            engine.select(taskID: try resolveTask(args["task"] ?? "other"))
            return status()
        case "add_note":
            guard let note = string(args["note"] ?? args["text"]), !note.isEmpty else { throw CommandError("add_note needs a note.") }
            let target = string(args["interval_id"]).flatMap(UUID.init(uuidString:))
                ?? store.interval(engine.lastWorkIntervalID)?.id
                ?? store.intervals.filter { $0.phase == .work }.max { $0.start < $1.start }?.id
            guard let id = target else { throw CommandError("There is no work interval to attach the note to.") }
            store.setNote(note, for: id)
            return describe(store.interval(id)!)
        case "add_interval":
            let taskID = try args["task"].map(resolveTask) ?? nil
            guard let minutes = double(args["minutes"]), minutes > 0 else { throw CommandError("add_interval needs minutes > 0.") }
            guard let startText = string(args["start"]), let start = Self.parseDate(startText) else {
                throw CommandError("add_interval needs start as ISO 8601, e.g. 2026-10-18T09:30:00.")
            }
            guard start.addingTimeInterval(minutes * 60) <= Date() else { throw CommandError("The interval must end before now.") }
            let outcome = Outcome(rawValue: string(args["outcome"]) ?? "completed") ?? .completed
            let interval = FocusInterval(taskID: taskID, phase: .work, start: start, duration: minutes * 60,
                                         outcome: outcome, note: string(args["note"]))
            store.addInterval(interval)
            return describe(interval)
        case "report":
            return try report(period: string(args["period"]) ?? "this week")
        case "forecast":
            guard let id = try resolveTask(args["task"] ?? ""), let task = store.task(id) else {
                throw CommandError("forecast needs a task.")
            }
            return forecast(task)
        case "set_goal":
            guard let goal = int(args["goal"]), (1...30).contains(goal) else { throw CommandError("goal must be 1–30.") }
            setTodayGoal(goal)
            return status()
        default:
            throw CommandError("Unknown command “\(command)”. Known: \(Self.commands.joined(separator: ", ")).")
        }
    }

    /// Changes today's goal; with per-weekday goals, only today's weekday.
    func setTodayGoal(_ goal: Int) {
        if var targets = store.settings.weekdayTargets, targets.count == 7 {
            targets[Calendar.current.component(.weekday, from: Date()) - 1] = goal
            store.settings.weekdayTargets = targets
        } else {
            store.settings.dailyTarget = goal
        }
    }

    // MARK: Results

    func status() -> [String: Any] {
        var result: [String: Any] = [
            "phase": engine.phase.rawValue,
            "status": engine.status.rawValue,
            "remaining_seconds": Int(engine.remaining.rounded(.up)),
            "duration_seconds": Int(engine.duration),
            "task": store.title(for: engine.taskID),
            "today": ["done": store.todayWorkCount, "goal": store.todayTarget],
            "streak_days": store.streak(),
            "cycle": ["done": engine.round, "long_break_after": store.durations(for: engine.taskID).longBreakAfter],
            "can_extend": engine.canExtend,
        ]
        if let id = engine.taskID { result["task_id"] = id.uuidString }
        if let away = engine.awaySince { result["away_since"] = Self.iso.string(from: away) }
        return result
    }

    private func describe(_ task: FocusTask) -> [String: Any] {
        var d: [String: Any] = [
            "id": task.id.uuidString, "title": task.title,
            "completed_intervals": store.completedWorkCount(for: task.id), "completed": task.isCompleted,
        ]
        if !task.note.isEmpty { d["note"] = task.note }
        if let e = task.estimatedIntervals { d["estimate"] = e }
        if let due = task.dueDate { d["due"] = Self.day.string(from: due) }
        if let type = store.workType(task.workTypeID) { d["work_type"] = type.name }
        return d
    }

    private func describe(_ i: FocusInterval) -> [String: Any] {
        var d: [String: Any] = [
            "id": i.id.uuidString, "task": store.title(for: i.taskID), "phase": i.phase.rawValue,
            "start": Self.iso.string(from: i.start), "minutes": Self.decimal(i.duration / 60),
            "outcome": i.outcome.rawValue,
        ]
        if let note = i.note { d["note"] = note }
        return d
    }

    private func report(period name: String) throws -> [String: Any] {
        guard let period = ReportPeriod.allCases.first(where: { $0.rawValue == name.lowercased().replacingOccurrences(of: "_", with: " ") }),
              period != .custom else {
            throw CommandError("period must be one of: \(ReportPeriod.allCases.filter { $0 != .custom }.map(\.rawValue).joined(separator: ", ")).")
        }
        let earliest = store.intervals.map(\.start).min() ?? Date()
        let range = period.range(customStart: Date(), customEnd: Date(), earliest: earliest)
        let work = store.intervals.filter { $0.phase == .work && range.contains($0.start) }
        let completed = work.filter { $0.outcome == .completed }
        var perTask: [String: (Int, TimeInterval)] = [:]
        for i in work {
            let title = store.title(for: i.taskID)
            let current = perTask[title] ?? (0, 0)
            perTask[title] = (current.0 + (i.outcome == .completed ? 1 : 0), current.1 + i.duration)
        }
        var result: [String: Any] = [
            "period": period.rawValue,
            "from": Self.day.string(from: range.lowerBound), "to": Self.day.string(from: range.upperBound),
            "work_hours": Self.decimal(work.reduce(0) { $0 + $1.duration } / 3600),
            "completed_intervals": completed.count, "skipped_intervals": work.count - completed.count,
            "tasks_completed": store.completedTasks.filter { range.contains($0.completedAt ?? .distantPast) }.count,
            "streak_days": store.streak(),
            "by_task": perTask.sorted { $0.value.1 > $1.value.1 }.map {
                ["task": $0.key, "completed_intervals": $0.value.0, "hours": Self.decimal($0.value.1 / 3600)]
            },
        ]
        if let c = Forecast.calibration(store: store) { result["estimate_ratio"] = Self.decimal(c.median, places: 2) }
        return result
    }

    private func forecast(_ task: FocusTask) -> [String: Any] {
        var d: [String: Any] = ["task": task.title, "completed_intervals": store.completedWorkCount(for: task.id)]
        if let e = task.estimatedIntervals { d["estimate"] = e }
        if let c = Forecast.calibration(store: store) {
            d["estimate_ratio"] = Self.decimal(c.median, places: 2)
            d["calibration_tasks"] = c.ratios.count
            if let e = task.estimatedIntervals { d["suggested_estimate"] = c.suggested(for: e) }
        }
        guard let r = Forecast.run(store: store, task: task) else {
            d["forecast"] = task.estimatedIntervals == nil
                ? "No estimate set. Add an estimate to get a finish date."
                : "Not enough history yet: needs at least 3 completed intervals on this task."
            return d
        }
        d["forecast"] = [
            "remaining_intervals": ["p10": r.remaining.low, "p50": r.remaining.median, "p90": r.remaining.high],
            "finish": ["p10": Self.day.string(from: r.finish.early), "p50": Self.day.string(from: r.finish.median),
                       "p90": Self.day.string(from: r.finish.late)],
            "weekly_pace": Self.decimal(r.weeklyPace), "weeks_sampled": r.weeksSampled,
            "calibrated": r.calibrated,
        ]
        return d
    }

    // MARK: Argument helpers

    /// Finds a task by id or title (exact, then unique prefix or substring). "other" is nil.
    func resolveTask(_ ref: Any) throws -> UUID? {
        guard let text = string(ref)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw CommandError("A task is required.")
        }
        if text.lowercased() == "other" { return nil }
        if let id = UUID(uuidString: text), store.task(id) != nil { return id }
        let candidates = store.activeTasks + store.completedTasks
        if let exact = candidates.first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame }) { return exact.id }
        let partial = candidates.filter { $0.title.localizedCaseInsensitiveContains(text) }
        if partial.count == 1 { return partial[0].id }
        if partial.isEmpty { throw CommandError("No task matches “\(text)”.") }
        throw CommandError("“\(text)” matches several tasks: \(partial.map(\.title).joined(separator: ", ")).")
    }

    private func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    private func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    private func bool(_ v: Any?) -> Bool? {
        switch v {
        case let n as NSNumber: n.boolValue
        case let s as String: ["1", "true", "yes"].contains(s.lowercased())
        default: nil
        }
    }

    /// Rounded number that serializes exactly (0.1, not 0.10000000000000001).
    nonisolated static func decimal(_ value: Double, places: Int = 1) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    nonisolated static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Accepts full ISO 8601, or local "YYYY-MM-DDTHH:MM[:SS]" / "YYYY-MM-DD HH:MM".
    nonisolated static func parseDate(_ text: String) -> Date? {
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
