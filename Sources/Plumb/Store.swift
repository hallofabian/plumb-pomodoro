import Foundation
import Observation

@MainActor
@Observable
final class Store {
    private(set) var library = Library()
    var settings: AppSettings {
        didSet { if settings != oldValue { scheduleSave(settings: true) } }
    }

    /// Called after every local change to synced data (not after merges from sync).
    @ObservationIgnored var onLocalLibraryChange: (() -> Void)?

    /// Description of the last undoable change, e.g. "interval deleted".
    private(set) var undoLabel: String?
    @ObservationIgnored private var undoAction: (() -> Void)?

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var saveLibraryPending = false
    @ObservationIgnored private var saveSettingsPending = false

    private var libraryURL: URL { directory.appendingPathComponent("library.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = (try? Data(contentsOf: directory.appendingPathComponent("settings.json"))).map(AppSettings.decode) ?? AppSettings()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("library.json")),
           let lib = try? JSONDecoder().decode(Library.self, from: data) {
            library = lib
        }
        migrateSoundNames()
        seedExamplesIfNeeded()
    }

    /// Before the rename, the app was called Fokus. Moves its data folder over once.
    nonisolated static func migrateLegacyDirectory(fileManager fm: FileManager = .default) {
        guard ProcessInfo.processInfo.environment["PLUMB_DATA_DIR"] == nil else { return }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("Fok" + "us", isDirectory: true)
        let current = defaultDirectory
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    /// Synth sounds were renamed along with the app ("fokus chime" → "plumb chime").
    private func migrateSoundNames() {
        let legacy = "fok" + "us "
        var s = settings
        if s.workEndSound.hasPrefix(legacy) { s.workEndSound = "plumb " + s.workEndSound.dropFirst(legacy.count) }
        if s.breakEndSound.hasPrefix(legacy) { s.breakEndSound = "plumb " + s.breakEndSound.dropFirst(legacy.count) }
        if s != settings {
            settings = s
            scheduleSave(settings: true)
        }
    }

    private func seedExamplesIfNeeded() {
        let example = WorkType.example5010
        // Early builds named the example "study"; rename it if it was never edited.
        if let i = library.workTypes.firstIndex(where: { $0.id == example.id && $0.name == "study" && $0.updatedAt == example.updatedAt }) {
            library.workTypes[i].name = example.name
            library.workTypes[i].updatedAt = Date()
            scheduleSave(library: true)
        }
        guard !settings.examplesSeeded else { return }
        if !library.workTypes.contains(where: { $0.id == example.id }) {
            library.workTypes.append(example)
        }
        settings.examplesSeeded = true
        scheduleSave(library: true, settings: true)
    }

    /// `PLUMB_DATA_DIR` overrides the location, e.g. to try things on a copy.
    nonisolated static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PLUMB_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plumb", isDirectory: true)
    }

    // MARK: Queries

    var tasks: [FocusTask] { library.tasks.filter { !$0.deleted } }
    var workTypes: [WorkType] { library.workTypes.filter { !$0.deleted }.sorted { $0.name < $1.name } }
    var intervals: [FocusInterval] { library.intervals.filter { !$0.deleted } }

    var activeTasks: [FocusTask] {
        tasks.filter { !$0.isCompleted }.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    var completedTasks: [FocusTask] {
        tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func task(_ id: UUID?) -> FocusTask? {
        guard let id else { return nil }
        return library.tasks.first { $0.id == id && !$0.deleted }
    }

    func title(for taskID: UUID?) -> String { task(taskID)?.title ?? L("Other") }

    func workType(_ id: UUID?) -> WorkType? {
        guard let id else { return nil }
        return library.workTypes.first { $0.id == id && !$0.deleted }
    }

    /// Timer durations for a task: its work type if it has one, else the global settings.
    func durations(for taskID: UUID?) -> Durations {
        workType(task(taskID)?.workTypeID)?.durations ?? settings.durations
    }

    func intervals(for taskID: UUID?) -> [FocusInterval] {
        intervals.filter { $0.taskID == taskID }.sorted { $0.start > $1.start }
    }

    func completedWorkCount(for taskID: UUID?) -> Int {
        intervals.filter { $0.taskID == taskID && $0.phase == .work && $0.outcome == .completed }.count
    }

    /// Seconds in one work interval of the task's work type.
    func intervalLength(for taskID: UUID?) -> TimeInterval { Double(max(1, durations(for: taskID).work) * 60) }

    /// All work time on a task, completed or skipped, in intervals of its work length.
    func workedIntervals(for taskID: UUID?) -> Double {
        let seconds = intervals.filter { $0.taskID == taskID && $0.phase == .work }.reduce(0) { $0 + $1.duration }
        return seconds / intervalLength(for: taskID)
    }

    var todayWorkCount: Int { completedWorkCount(on: Date()) }

    var todayTarget: Int { settings.target(on: Date()) }

    /// "3/8", or "3 · rest day" when today's goal is 0.
    var todayProgress: String {
        todayTarget == 0 ? L("%@ · rest day", "\(todayWorkCount)") : "\(todayWorkCount)/\(todayTarget)"
    }

    func completedWorkCount(on day: Date, calendar: Calendar = .current) -> Int {
        intervals.filter { $0.phase == .work && $0.outcome == .completed && calendar.isDate($0.start, inSameDayAs: day) }.count
    }

    func intervals(on day: Date, calendar: Calendar = .current) -> [FocusInterval] {
        intervals.filter { calendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
    }

    /// Consecutive days that met their goal, ending today (if met) or yesterday.
    /// Rest days (goal 0) are skipped without breaking the streak.
    func streak(asOf now: Date = Date(), calendar: Calendar = .current) -> Int {
        var counts: [Date: Int] = [:]
        for i in intervals where i.phase == .work && i.outcome == .completed {
            counts[calendar.startOfDay(for: i.start), default: 0] += 1
        }
        var day = calendar.startOfDay(for: now)
        var streak = 0
        let todayMet = (counts[day] ?? 0) >= max(1, settings.target(on: day))
        if todayMet { streak = 1 }
        for _ in 0..<3650 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            let target = settings.target(on: day, calendar: calendar)
            if target == 0 { continue }
            guard (counts[day] ?? 0) >= target else { break }
            streak += 1
        }
        return streak
    }

    // MARK: Undo

    func registerUndo(_ label: String, _ action: @escaping () -> Void) {
        undoLabel = label
        undoAction = action
    }

    func undo() {
        let action = undoAction
        undoAction = nil
        undoLabel = nil
        action?()
    }

    func clearUndo() {
        undoAction = nil
        undoLabel = nil
    }

    private func restore(intervals ids: [UUID]) {
        let now = Date()
        for i in library.intervals.indices where ids.contains(library.intervals[i].id) {
            library.intervals[i].deleted = false
            library.intervals[i].updatedAt = now
        }
        localChange()
    }

    // MARK: Task mutations

    @discardableResult
    func addTask(title: String) -> FocusTask {
        let minIndex = activeTasks.first?.sortIndex ?? 0
        let task = FocusTask(title: title, sortIndex: minIndex - 1)
        library.tasks.append(task)
        localChange()
        return task
    }

    func update(_ task: FocusTask) {
        guard let i = library.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var task = task
        guard task != library.tasks[i] else { return }
        task.updatedAt = Date()
        library.tasks[i] = task
        localChange()
    }

    func setCompleted(_ id: UUID, _ completed: Bool) {
        guard var task = task(id) else { return }
        let previous = task.completedAt
        task.completedAt = completed ? Date() : nil
        update(task)
        if completed {
            registerUndo(L("“%@” completed", "\(task.title)")) { [weak self] in
                guard var t = self?.task(id) else { return }
                t.completedAt = previous
                self?.update(t)
            }
        }
    }

    /// Deletes a task; its intervals move to "Other" so no history is lost.
    func deleteTask(_ id: UUID) {
        guard let i = library.tasks.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        library.tasks[i].deleted = true
        library.tasks[i].updatedAt = now
        var moved: [UUID] = []
        for j in library.intervals.indices where library.intervals[j].taskID == id {
            library.intervals[j].taskID = nil
            library.intervals[j].updatedAt = now
            moved.append(library.intervals[j].id)
        }
        localChange()
        registerUndo(L("“%@” deleted", "\(library.tasks[i].title)")) { [weak self] in
            guard let self, let k = self.library.tasks.firstIndex(where: { $0.id == id }) else { return }
            let now = Date()
            self.library.tasks[k].deleted = false
            self.library.tasks[k].updatedAt = now
            for j in self.library.intervals.indices where moved.contains(self.library.intervals[j].id) {
                self.library.intervals[j].taskID = id
                self.library.intervals[j].updatedAt = now
            }
            self.localChange()
        }
    }

    func moveActiveTasks(from source: IndexSet, to destination: Int) {
        var ordered = activeTasks
        ordered.move(fromOffsets: source, toOffset: destination)
        let now = Date()
        for (index, task) in ordered.enumerated() {
            guard let i = library.tasks.firstIndex(where: { $0.id == task.id }),
                  library.tasks[i].sortIndex != Double(index) else { continue }
            library.tasks[i].sortIndex = Double(index)
            library.tasks[i].updatedAt = now
        }
        localChange()
    }

    // MARK: Interval mutations

    func addInterval(_ interval: FocusInterval) {
        library.intervals.append(interval)
        localChange()
    }

    func update(_ interval: FocusInterval) {
        guard let i = library.intervals.firstIndex(where: { $0.id == interval.id }) else { return }
        var interval = interval
        guard interval != library.intervals[i] else { return }
        interval.updatedAt = Date()
        library.intervals[i] = interval
        localChange()
    }

    func deleteInterval(_ id: UUID) {
        guard let i = library.intervals.firstIndex(where: { $0.id == id }) else { return }
        library.intervals[i].deleted = true
        library.intervals[i].updatedAt = Date()
        localChange()
        registerUndo(L("interval deleted")) { [weak self] in self?.restore(intervals: [id]) }
    }

    /// Deletes without offering undo (used when the timer reopens its own interval).
    func discardInterval(_ id: UUID) {
        guard let i = library.intervals.firstIndex(where: { $0.id == id }) else { return }
        library.intervals[i].deleted = true
        library.intervals[i].updatedAt = Date()
        localChange()
    }

    func interval(_ id: UUID?) -> FocusInterval? {
        guard let id else { return nil }
        return library.intervals.first { $0.id == id && !$0.deleted }
    }

    func setNote(_ note: String, for id: UUID) {
        guard var interval = interval(id) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        interval.note = trimmed.isEmpty ? nil : trimmed
        update(interval)
    }

    // MARK: Work type mutations

    func save(_ workType: WorkType) {
        var workType = workType
        workType.updatedAt = Date()
        if let i = library.workTypes.firstIndex(where: { $0.id == workType.id }) {
            guard library.workTypes[i] != workType else { return }
            library.workTypes[i] = workType
        } else {
            library.workTypes.append(workType)
        }
        localChange()
    }

    func deleteWorkType(_ id: UUID) {
        guard let i = library.workTypes.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        library.workTypes[i].deleted = true
        library.workTypes[i].updatedAt = now
        for j in library.tasks.indices where library.tasks[j].workTypeID == id {
            library.tasks[j].workTypeID = nil
            library.tasks[j].updatedAt = now
        }
        localChange()
    }

    // MARK: Sync & import

    /// Applies records from another Mac or an import. Returns true if anything changed.
    @discardableResult
    func merge(_ other: Library, isLocalChange: Bool = false) -> Bool {
        var lib = library
        guard lib.merge(other) else { return false }
        library = lib
        if isLocalChange { localChange() } else { scheduleSave(library: true) }
        return true
    }

    // MARK: Persistence

    private func localChange() {
        scheduleSave(library: true)
        onLocalLibraryChange?()
    }

    private func scheduleSave(library: Bool = false, settings: Bool = false) {
        saveLibraryPending = saveLibraryPending || library
        saveSettingsPending = saveSettingsPending || settings
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if saveLibraryPending, let data = try? encoder.encode(library.normalized) {
            try? data.write(to: libraryURL, options: .atomic)
        }
        if saveSettingsPending, let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
        saveLibraryPending = false
        saveSettingsPending = false
    }
}
