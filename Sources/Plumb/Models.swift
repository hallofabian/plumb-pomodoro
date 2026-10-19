import Foundation

/// A record that participates in folder sync. Conflicts resolve last-writer-wins on
/// `updatedAt`; deletions are kept as tombstones so they propagate to other Macs.
protocol SyncRecord: Codable, Identifiable, Equatable where ID == UUID {
    var id: UUID { get }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
}

enum Phase: String, Codable, CaseIterable {
    case work, shortBreak, longBreak

    var isBreak: Bool { self != .work }

    var title: String {
        switch self {
        case .work: L("Work")
        case .shortBreak: L("Short Break")
        case .longBreak: L("Long Break")
        }
    }
}

enum Outcome: String, Codable {
    case completed, skipped
}

struct WorkType: SyncRecord, Hashable {
    var id = UUID()
    var name: String
    var durations = Durations()
    var updatedAt = Date()
    var deleted = false

    /// Example shipped with the app. The fixed id makes every Mac add the same
    /// record, so sync merges them instead of duplicating; the epoch timestamp
    /// lets any real edit or deletion win.
    static let example5010 = WorkType(
        id: UUID(uuidString: "5D0C3A11-57D7-4E00-8000-000000005010")!,
        name: "50/10",
        durations: Durations(work: 50, shortBreak: 10, longBreak: 30, longBreakAfter: 4),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

struct FocusTask: SyncRecord, Hashable {
    var id = UUID()
    var title: String
    var note = ""
    var estimatedIntervals: Int?
    var dueDate: Date?
    var completedAt: Date?
    var workTypeID: UUID?
    var createdAt = Date()
    var sortIndex: Double = 0
    var updatedAt = Date()
    var deleted = false

    var isCompleted: Bool { completedAt != nil }
}

/// One timer run. `taskID == nil` means the built-in task "Other".
struct FocusInterval: SyncRecord, Hashable {
    var id = UUID()
    var taskID: UUID?
    var phase: Phase
    var start: Date
    /// Seconds actually spent running (pauses excluded).
    var duration: TimeInterval
    var outcome: Outcome
    /// What got done, written after the interval.
    var note: String?
    var updatedAt = Date()
    var deleted = false

    var end: Date { start.addingTimeInterval(duration) }
}

struct Durations: Codable, Hashable {
    var work = 25
    var shortBreak = 5
    var longBreak = 15
    var longBreakAfter = 4

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .work: work
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

/// Everything that is synced between Macs.
struct Library: Codable, Equatable {
    var tasks: [FocusTask] = []
    var workTypes: [WorkType] = []
    var intervals: [FocusInterval] = []

    /// Records sorted by id so the encoded file only changes when content changes.
    var normalized: Library {
        Library(
            tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString },
            workTypes: workTypes.sorted { $0.id.uuidString < $1.id.uuidString },
            intervals: intervals.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    /// Merges `other` into `self` record by record. Returns true if anything changed.
    @discardableResult
    mutating func merge(_ other: Library) -> Bool {
        let t = Library.merge(tasks, other.tasks)
        let w = Library.merge(workTypes, other.workTypes)
        let i = Library.merge(intervals, other.intervals)
        if t.changed { tasks = t.merged }
        if w.changed { workTypes = w.merged }
        if i.changed { intervals = i.merged }
        return t.changed || w.changed || i.changed
    }

    static func merge<T: SyncRecord>(_ local: [T], _ remote: [T]) -> (merged: [T], changed: Bool) {
        var byID: [UUID: T] = [:]
        for record in local {
            if let existing = byID[record.id], !wins(record, over: existing) { continue }
            byID[record.id] = record
        }
        var changed = byID.count != local.count
        for record in remote {
            if let existing = byID[record.id], !wins(record, over: existing) { continue }
            if byID[record.id] != record {
                byID[record.id] = record
                changed = true
            }
        }
        return (changed ? Array(byID.values) : local, changed)
    }

    private static func wins<T: SyncRecord>(_ candidate: T, over existing: T) -> Bool {
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        // Same timestamp: a deletion beats an edit so deletes never resurrect.
        return candidate.deleted && !existing.deleted
    }
}

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, ...).
    var modifiers: UInt32
    var display: String
}

enum BlockMode: String, Codable, CaseIterable {
    case blockList, allowList

    var title: String { self == .blockList ? L("Block list") : L("Allow list") }
}

struct BlockedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

enum AutomationEvent: String, Codable, CaseIterable, Identifiable {
    case workStarted, workPaused, workEnded, breakStarted, breakEnded, taskCompleted, taskSelected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workStarted: L("Work interval started")
        case .workPaused: L("Work interval paused")
        case .workEnded: L("Work interval ended")
        case .breakStarted: L("Break started")
        case .breakEnded: L("Break ended")
        case .taskCompleted: L("Task completed")
        case .taskSelected: L("Task selected")
        }
    }
}

enum TimerStatus: String, Codable {
    case idle, running, paused
}

/// Persisted timer state, so quitting the app does not lose a running interval.
struct TimerSnapshot: Codable, Equatable {
    var phase: Phase
    var status: TimerStatus
    var duration: TimeInterval
    var accumulated: TimeInterval
    var runStartedAt: Date?
    var phaseStartedAt: Date?
    var lastPhaseEndedAt: Date?
    var round: Int
    var taskID: UUID?
    // Added later; optional so older saved snapshots still decode.
    var awaySince: Date?
    var lastWorkIntervalID: UUID?
}

/// Per-Mac settings. Not synced.
struct AppSettings: Codable, Equatable {
    var deviceID = UUID()
    var durations = Durations()
    var dailyTarget = 8
    var autoStart = false
    var skipBreakIfIdle = true
    var showOtherTask = true
    var showTimerInMenuBar = true
    var preventSleep = false
    var appearance = 0
    var notificationsEnabled = true
    var workEndSound = "plumb chime"
    var breakEndSound = "plumb bell"
    var soundVolume = 1.0
    /// Background sound id from `AmbientSource.catalog`.
    var ambientSource = "off"
    var ambientCustomURL: String?
    var ambientVolume = 0.5
    var ambientDuringBreaks = false
    var startPauseHotKey: HotKey?
    var skipHotKey: HotKey?
    var blockingEnabled = false
    var blockMode = BlockMode.blockList
    var blockApps: [BlockedApp] = []
    var allowApps: [BlockedApp] = []
    var blockSites: [String] = []
    var allowSites: [String] = []
    var shortcuts: [String: String] = [:]
    var syncFolderBookmark: Data?
    var syncFolderPath: String?
    var timer: TimerSnapshot?
    /// The example work types were added once; deleting them stays deleted.
    var examplesSeeded = false
    /// Goal per weekday, Sunday first (Calendar weekday − 1). nil = `dailyTarget` every day.
    /// A 0 marks a rest day, which does not break a streak.
    var weekdayTargets: [Int]?
    var awayDetection = true
    var awayMinutes = 10
    var breakScreen = false
    var extendMinutes = 5
    /// First launch set up default shortcuts and offered the Be Focused import.
    var firstRunDone = false
    /// "system", "en" or "de"; applied at launch.
    var language = "system"

    /// The goal for the day containing `date`.
    func target(on date: Date, calendar: Calendar = .current) -> Int {
        guard let targets = weekdayTargets, targets.count == 7 else { return dailyTarget }
        return targets[calendar.component(.weekday, from: date) - 1]
    }

    /// Decodes saved settings on top of the defaults, so fields added in later
    /// versions get their default instead of failing the whole decode.
    static func decode(_ data: Data) -> AppSettings {
        guard
            let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any],
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 }),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: merged)
        else { return AppSettings() }
        return settings
    }
}
