import Foundation
import Testing
@testable import Plumb

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct MergeTests {
    @Test func newerEditWins() {
        let id = UUID()
        let old = FocusTask(id: id, title: "Old", updatedAt: Date(timeIntervalSince1970: 100))
        let new = FocusTask(id: id, title: "New", updatedAt: Date(timeIntervalSince1970: 200))
        var a = Library(tasks: [old])
        let changed = a.merge(Library(tasks: [new]))
        #expect(changed)
        #expect(a.tasks.map(\.title) == ["New"])
        // Merging the older copy back changes nothing.
        let changedAgain = a.merge(Library(tasks: [old]))
        #expect(!changedAgain)
        #expect(a.tasks.map(\.title) == ["New"])
    }

    @Test func deletionPropagatesAndWinsTies() {
        let id = UUID()
        let t = Date(timeIntervalSince1970: 100)
        let live = FocusTask(id: id, title: "X", updatedAt: t)
        var gone = live
        gone.deleted = true
        var a = Library(tasks: [live])
        let deleted = a.merge(Library(tasks: [gone]))
        #expect(deleted)
        #expect(a.tasks.first?.deleted == true)
        var b = Library(tasks: [gone])
        let resurrected = b.merge(Library(tasks: [live]))
        #expect(!resurrected)
    }

    @Test func mergeIsSymmetric() {
        let shared = UUID()
        let a1 = FocusInterval(taskID: nil, phase: .work, start: Date(), duration: 1500, outcome: .completed)
        let b1 = FocusInterval(taskID: nil, phase: .work, start: Date(), duration: 1500, outcome: .skipped)
        let x = FocusTask(id: shared, title: "A", updatedAt: Date(timeIntervalSince1970: 5))
        let y = FocusTask(id: shared, title: "B", updatedAt: Date(timeIntervalSince1970: 9))
        var left = Library(tasks: [x], intervals: [a1])
        var right = Library(tasks: [y], intervals: [b1])
        let leftCopy = left
        left.merge(right)
        right.merge(leftCopy)
        #expect(left.normalized == right.normalized)
        #expect(left.tasks.first?.title == "B")
        #expect(left.intervals.count == 2)
    }
}

@MainActor @Suite struct TimerTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var idle: TimeInterval = 0
    }

    private func makeEngine() -> (Store, TimerEngine, Clock) {
        let store = Store(directory: tempDir())
        store.settings.durations = Durations(work: 25, shortBreak: 5, longBreak: 15, longBreakAfter: 2)
        store.settings.awayMinutes = 5
        let engine = TimerEngine(store: store)
        let clock = Clock()
        engine.clock = { clock.now }
        engine.idleSeconds = { clock.idle }
        return (store, engine, clock)
    }

    @Test func awayPausesRetroactivelyAndKeep() {
        let (_, engine, clock) = makeEngine()
        engine.start()
        let started = clock.now
        clock.now += 15 * 60
        clock.idle = 10 * 60 // left 10 minutes ago
        engine.tick()
        #expect(engine.status == .paused)
        #expect(engine.awaySince == started + 5 * 60)
        #expect(engine.accumulated == 5 * 60)
        clock.idle = 0
        engine.resolveAway(.keep)
        #expect(engine.status == .running)
        #expect(engine.elapsed == 15 * 60)
    }

    @Test func resumingAfterNoInputKeepsTheTime() {
        let (_, engine, clock) = makeEngine()
        engine.start()
        clock.now += 15 * 60
        clock.idle = 10 * 60 // reading, no input
        engine.tick()
        #expect(engine.awaySince != nil)
        clock.idle = 0
        engine.toggle() // space or "resume"
        #expect(engine.awaySince == nil)
        #expect(engine.status == .running)
        #expect(engine.elapsed == 15 * 60)
    }

    @Test func awayDropAndEnd() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 15 * 60
        clock.idle = 10 * 60
        engine.tick()
        clock.idle = 0
        engine.resolveAway(.drop)
        #expect(engine.elapsed == 5 * 60)

        clock.now += 60
        clock.idle = 6 * 60
        engine.tick()
        #expect(engine.awaySince != nil)
        engine.resolveAway(.end)
        #expect(store.intervals.last?.outcome == .skipped)
        #expect(engine.phase == .shortBreak)
    }

    @Test func sleepingThroughCountsOnlyTimeBeforeSleep() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 3 * 60
        engine.tick()
        clock.now += 5 * 3600
        clock.idle = 5 * 3600 // lid closed after 3 minutes
        engine.tick()
        #expect(store.intervals.isEmpty)
        #expect(engine.accumulated == 3 * 60)
        #expect(engine.awaySince != nil)
    }

    @Test func extendWhileRunningAndAfterEnd() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        engine.extend(minutes: 5)
        #expect(engine.duration == 30 * 60)
        clock.now += 30 * 60
        engine.tick()
        #expect(engine.phase == .shortBreak)
        #expect(store.intervals.count == 1)
        clock.now += 60
        engine.extend(minutes: 5)
        #expect(engine.phase == .work && engine.status == .running)
        #expect(store.intervals.isEmpty) // reopened, not duplicated
        clock.now += 5 * 60
        engine.tick()
        #expect(store.intervals.count == 1)
        #expect(store.intervals[0].duration == 35 * 60)
        #expect(engine.round == 1)
    }

    @Test func keepWorkingFromABreakAlwaysWorks() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 300
        engine.skip() // no reopenable interval now
        #expect(engine.phase == .shortBreak && !engine.canExtend)
        engine.start()
        clock.now += 60
        engine.keepWorking(minutes: 5)
        #expect(engine.phase == .work && engine.isRunning)
        #expect(engine.duration == 5 * 60)
        #expect(store.intervals.filter { $0.phase == .shortBreak }.first?.outcome == .skipped)
        clock.now += 5 * 60
        engine.tick()
        let lastWork = store.intervals.last { $0.phase == .work }
        #expect(lastWork?.duration == TimeInterval(300))
        #expect(lastWork?.outcome == .completed)
    }

    @Test func adjustIdleDuration() {
        let (_, engine, _) = makeEngine()
        engine.adjustIdleDuration(byMinutes: 3)
        #expect(engine.duration == 28 * 60)
        engine.start()
        #expect(engine.duration == 28 * 60)
    }

    @Test func fullCycleWithLongBreak() {
        let (store, engine, clock) = makeEngine()
        var phases: [Phase] = []
        for _ in 0..<4 {
            phases.append(engine.phase)
            engine.start()
            clock.now += engine.duration
            engine.tick()
        }
        #expect(phases == [.work, .shortBreak, .work, .longBreak])
        #expect(engine.phase == .work)
        #expect(engine.round == 0)
        let work = store.intervals.filter { $0.phase == .work }
        #expect(work.count == 2)
        #expect(work.allSatisfy { $0.outcome == .completed && $0.duration == 1500 })
    }

    @Test func pausesAreExcluded() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 600
        engine.pause()
        clock.now += 3600
        engine.tick()
        #expect(engine.remaining == 900)
        engine.start()
        clock.now += 900
        engine.tick()
        #expect(store.intervals.count == 1)
        #expect(store.intervals[0].duration == 1500)
        #expect(engine.phase == .shortBreak)
    }

    @Test func sleepingPastTheEndRecordsRealEnd() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        let started = clock.now
        clock.now += 5 * 3600 // lid closed for hours
        engine.tick()
        #expect(store.intervals.first?.start == started)
        #expect(store.intervals.first?.duration == 1500)
        #expect(engine.lastPhaseEndedAt == started + 1500)
    }

    @Test func skipRecordsSkippedAndAdvances() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 300
        engine.skip()
        #expect(store.intervals.first?.outcome == .skipped)
        #expect(store.intervals.first?.duration == 300)
        #expect(engine.phase == .shortBreak)
        #expect(engine.status == .idle)
    }

    @Test func idleBreakIsSkipped() {
        let (_, engine, clock) = makeEngine()
        engine.start()
        clock.now += 1500
        engine.tick()
        #expect(engine.phase == .shortBreak)
        clock.now += 2 * 3600
        engine.start()
        #expect(engine.phase == .work)
    }

    @Test func workTypeOverridesDurations() {
        let (store, engine, _) = makeEngine()
        let type = WorkType(name: "Study", durations: Durations(work: 50, shortBreak: 10, longBreak: 30, longBreakAfter: 4))
        store.save(type)
        var task = store.addTask(title: "Thesis")
        task.workTypeID = type.id
        store.update(task)
        engine.select(taskID: task.id)
        #expect(engine.duration == 50 * 60)
    }

    @Test func stateSurvivesRestart() {
        let (store, engine, clock) = makeEngine()
        engine.start()
        clock.now += 100
        let restored = TimerEngine(store: store)
        #expect(restored.status == .running)
        #expect(restored.runStartedAt == engine.runStartedAt)
    }
}

@MainActor @Suite struct StoreTests {
    @Test func deletingTaskKeepsIntervalsAsOther() {
        let store = Store(directory: tempDir())
        let task = store.addTask(title: "T")
        store.addInterval(FocusInterval(taskID: task.id, phase: .work, start: Date(), duration: 60, outcome: .completed))
        store.deleteTask(task.id)
        #expect(store.tasks.isEmpty)
        #expect(store.intervals.first?.taskID == nil)
    }

    @Test func persistsToDisk() {
        let dir = tempDir()
        let store = Store(directory: dir)
        store.addTask(title: "Persist me")
        store.settings.dailyTarget = 11
        store.saveNow()
        let reloaded = Store(directory: dir)
        #expect(reloaded.tasks.map(\.title) == ["Persist me"])
        #expect(reloaded.settings.dailyTarget == 11)
    }

    @Test func exampleWorkTypeIsSeededOnceAndStaysDeleted() {
        let dir = tempDir()
        let store = Store(directory: dir)
        let example = store.workTypes.first { $0.name == "50/10" }
        #expect(example?.durations == Durations(work: 50, shortBreak: 10, longBreak: 30, longBreakAfter: 4))
        store.deleteWorkType(WorkType.example5010.id)
        store.saveNow()
        let reloaded = Store(directory: dir)
        #expect(reloaded.workTypes.isEmpty)
    }

    @Test func renamesUneditedOldExample() {
        let dir = tempDir()
        var old = WorkType.example5010
        old.name = "study"
        let data = try! JSONEncoder().encode(Library(workTypes: [old]))
        try! data.write(to: dir.appendingPathComponent("library.json"))
        try! Data(#"{"examplesSeeded": true}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = Store(directory: dir)
        #expect(store.workTypes.map(\.name) == ["50/10"])
    }

    @Test func renamesLegacySoundNames() throws {
        let dir = tempDir()
        try Data(#"{"workEndSound": "fokus chime", "breakEndSound": "Glass"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = Store(directory: dir)
        #expect(store.settings.workEndSound == "plumb chime")
        #expect(store.settings.breakEndSound == "Glass")
    }

    @Test func settingsToleratesMissingFields() {
        let settings = AppSettings.decode(Data(#"{"dailyTarget": 3}"#.utf8))
        #expect(settings.dailyTarget == 3)
        #expect(settings.durations.work == 25)
    }

    @Test func csvEscapes() {
        let store = Store(directory: tempDir())
        let task = store.addTask(title: "Write \"thesis\", chapter 2")
        store.addInterval(FocusInterval(taskID: task.id, phase: .work, start: Date(), duration: 1500, outcome: .completed))
        let csv = CSVExport.csv(store: store)
        #expect(csv.contains("\"Write \"\"thesis\"\", chapter 2\""))
        #expect(csv.contains(",25.00,"))
    }
}

@MainActor @Suite struct ImportTests {
    @Test func parsesBeFocusedTree() {
        let root: [String: Any] = [
            "className": "PMLocalDataTreeItem",
            "children": [
                ["className": "PMAppSettings", "pomodoroLenght": 50, "restTime": 10, "bigRestTime": 30,
                 "pomodorosInPeriodCount": 4, "pomodorosPerDay": 8, "children": []],
                ["className": "PMTask", "id": "A1B2C3D4-0000-4000-8000-000000000001", "title": "Thesis",
                 "completionState": 0, "creationTime": 1_780_000_000.0, "expectedIntervals": -1, "note": "", "children": []],
                ["className": "PMPomodoro", "id": "A1B2C3D4-0000-4000-8000-000000000002", "isRest": false,
                 "completionState": 3, "commonTimeInterval": 3000.0, "startTimeStamp": 1_784_600_000.0,
                 "parentTaskID": "A1B2C3D4-0000-4000-8000-000000000001"],
                ["className": "PMPomodoro", "id": "A1B2C3D4-0000-4000-8000-000000000003", "isRest": true,
                 "completionState": 4, "commonTimeInterval": 1800.0, "startTimeStamp": 1_784_603_000.0,
                 "parentTaskID": "PMDefaultTask"],
            ] as [Any],
        ]
        let (lib, durations, target) = BeFocusedImport.parse(root)
        #expect(durations == Durations(work: 50, shortBreak: 10, longBreak: 30, longBreakAfter: 4))
        #expect(target == 8)
        #expect(lib.tasks.count == 1 && lib.tasks[0].title == "Thesis" && !lib.tasks[0].isCompleted)
        #expect(lib.tasks[0].estimatedIntervals == nil)
        let work = lib.intervals.first { $0.phase == .work }
        #expect(work?.taskID == lib.tasks[0].id && work?.outcome == .completed && work?.duration == 3000)
        let rest = lib.intervals.first { $0.phase != .work }
        #expect(rest?.phase == .longBreak && rest?.outcome == .skipped && rest?.taskID == nil)
    }

    /// Runs against the real Be Focused data on this Mac when it is present.
    @Test func importsRealFileIdempotently() throws {
        let file = BeFocusedImport.defaultFile
        guard FileManager.default.isReadableFile(atPath: file.path) else { return }
        let store = Store(directory: tempDir())
        let first = try BeFocusedImport.importFile(file, into: store, importSettings: true)
        #expect(first.tasks > 0 && first.intervals > 0)
        let count = store.library.intervals.count
        _ = try BeFocusedImport.importFile(file, into: store, importSettings: false)
        #expect(store.library.intervals.count == count)
    }
}

@Suite struct BlockerTests {
    @Test func hostMatching() {
        #expect(Blocker.host("www.youtube.com", matches: "youtube.com"))
        #expect(Blocker.host("m.youtube.com", matches: "https://www.youtube.com/feed"))
        #expect(!Blocker.host("notyoutube.com", matches: "youtube.com"))
        #expect(!Blocker.host("example.com", matches: ""))
    }
}

@MainActor @Suite struct FolderSyncTests {
    /// Two "Macs" sharing one folder converge, and each only writes its own file.
    @Test func twoDevicesConverge() async throws {
        let shared = tempDir()
        let storeA = Store(directory: tempDir())
        let storeB = Store(directory: tempDir())
        for store in [storeA, storeB] {
            store.settings.syncFolderPath = shared.path
        }
        storeA.addTask(title: "From A")
        storeB.addTask(title: "From B")
        let syncA = FolderSync(store: storeA)
        let syncB = FolderSync(store: storeB)
        syncA.start()
        try await waitUntilIdle(syncA)
        syncB.start()
        try await waitUntilIdle(syncB)
        syncA.syncNow()
        try await waitUntilIdle(syncA)

        #expect(Set(storeA.tasks.map(\.title)) == ["From A", "From B"])
        #expect(Set(storeB.tasks.map(\.title)) == ["From A", "From B"])
        let files = try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent(FolderSync.subfolder).path)
        #expect(files.sorted() == [storeA.settings.deviceID.uuidString + ".json", storeB.settings.deviceID.uuidString + ".json"].sorted())

        // A deletion on B reaches A.
        let fromA = try #require(storeB.tasks.first { $0.title == "From A" })
        storeB.deleteTask(fromA.id)
        syncB.syncNow()
        try await waitUntilIdle(syncB)
        syncA.syncNow()
        try await waitUntilIdle(syncA)
        #expect(storeA.tasks.map(\.title) == ["From B"])
        syncA.disconnect()
        syncB.disconnect()
    }

    private func waitUntilIdle(_ sync: FolderSync) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(20))
            if !sync.isSyncing { return }
        }
        Issue.record("sync did not finish")
    }
}

@MainActor @Suite struct GoalAndUndoTests {
    private func addWork(_ store: Store, daysAgo: Int, count: Int) {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
        for i in 0..<count {
            store.addInterval(FocusInterval(taskID: nil, phase: .work, start: day.addingTimeInterval(Double(9 * 3600 + i * 1800)),
                                            duration: 1500, outcome: .completed))
        }
    }

    @Test func streakCountsGoalDaysAndSkipsRestDays() {
        let store = Store(directory: tempDir())
        store.settings.dailyTarget = 2
        addWork(store, daysAgo: 1, count: 2)
        addWork(store, daysAgo: 2, count: 3)
        addWork(store, daysAgo: 4, count: 2) // day 3 missed
        #expect(store.streak() == 2)
        addWork(store, daysAgo: 0, count: 2)
        #expect(store.streak() == 3)
        // Make the missed day a rest day.
        let missed = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        var targets = Array(repeating: 2, count: 7)
        targets[Calendar.current.component(.weekday, from: missed) - 1] = 0
        store.settings.weekdayTargets = targets
        #expect(store.streak() == 4)
    }

    @Test func weekdayTargets() {
        var settings = AppSettings()
        settings.weekdayTargets = [0, 8, 8, 8, 8, 6, 3]
        let saturday = DateComponents(calendar: .current, year: 2026, month: 10, day: 17).date!
        #expect(settings.target(on: saturday) == 3)
    }

    @Test func undoRestoresIntervalAndTask() {
        let store = Store(directory: tempDir())
        let task = store.addTask(title: "Thesis")
        let interval = FocusInterval(taskID: task.id, phase: .work, start: Date(), duration: 60, outcome: .completed)
        store.addInterval(interval)
        store.deleteInterval(interval.id)
        #expect(store.intervals.isEmpty)
        store.undo()
        #expect(store.intervals.count == 1)
        store.deleteTask(task.id)
        #expect(store.intervals.first?.taskID == nil)
        store.undo()
        #expect(store.task(task.id) != nil)
        #expect(store.intervals.first?.taskID == task.id)
        #expect(store.undoLabel == nil)
    }
}

@Suite struct ForecastTests {
    @Test func steadyPaceWithoutCalibration() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let r = try #require(Forecast.run(done: 4, estimate: 20, ratios: [], weeklyWork: [4, 4, 4, 4], from: start))
        #expect(r.remaining.median == 16)
        #expect(r.finish.median == start.addingTimeInterval(28 * 86400))
        // Identical weeks give no spread; the forecast must say it rests on little data.
        #expect(r.finish.early == r.finish.late)
        #expect(!r.calibrated)
        #expect(r.littleData)
    }

    @Test func calibrationWidensAndShiftsTheRange() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let c = try #require(Forecast.calibration(ratios: [1.0, 1.5, 2.0]))
        #expect(c.median == 1.5)
        #expect(c.suggested(for: 10) == 15)
        let r = try #require(Forecast.run(done: 0, estimate: 10, ratios: c.ratios, weeklyWork: [2, 5, 3, 0, 4], from: start))
        #expect(r.remaining.low == 10 && r.remaining.high == 20)
        #expect(r.finish.early < r.finish.median && r.finish.median < r.finish.late)
        #expect(r.calibrated && r.tasksCalibrated == 3)
        #expect(r.littleData) // only 3 finished tasks
        let solid = try #require(Forecast.run(done: 0, estimate: 10, ratios: [1, 1.2, 1.5, 1.5, 2],
                                              weeklyWork: [2, 5, 3, 0, 4], from: start))
        #expect(!solid.littleData)
    }

    @Test func needsHistory() {
        #expect(Forecast.run(done: 0, estimate: 10, ratios: [], weeklyWork: [1, 1], from: Date()) == nil)
        #expect(Forecast.calibration(ratios: [1, 2]) == nil)
    }

    /// Two 50-minute intervals on a 25-minute task are four intervals of work,
    /// and a skipped 10-minute one counts for its 10 minutes.
    @MainActor @Test func countsWorkTimeNotIntervals() throws {
        let store = Store(directory: tempDir())
        let task = store.addTask(title: "thesis")
        let now = Date()
        for (minutes, outcome) in [(50, Outcome.completed), (50, .completed), (10, .skipped)] {
            store.addInterval(FocusInterval(taskID: task.id, phase: .work, start: now.addingTimeInterval(-7200),
                                            duration: Double(minutes * 60), outcome: outcome))
        }
        #expect(store.workedIntervals(for: task.id) == 4.4)
        #expect(Forecast.weeklyWork(store: store, taskID: task.id, now: now).last == 4.4)
        var estimated = task
        estimated.estimatedIntervals = 10
        store.update(estimated)
        let r = try #require(Forecast.run(store: store, task: estimated, now: now))
        #expect(r.remaining.median == 6) // 5.6 rounded up
    }
}

@MainActor @Suite struct CommandTests {
    private func make() -> (Store, TimerEngine, CommandCenter) {
        let store = Store(directory: tempDir())
        let engine = TimerEngine(store: store)
        engine.idleSeconds = { 0 }
        return (store, engine, CommandCenter(store: store, engine: engine))
    }

    @Test func addTaskAndStartByPartialName() throws {
        let (store, engine, commands) = make()
        let added = try commands.run("add_task", ["title": "Thesis", "estimate": 40, "work_type": "50/10"]) as! [String: Any]
        #expect(added["estimate"] as? Int == 40)
        #expect(added["work_type"] as? String == "50/10")
        _ = try commands.run("add_task", ["title": "Read paper"])
        let status = try commands.run("start", ["task": "thes"]) as! [String: Any]
        #expect(status["task"] as? String == "Thesis")
        #expect(engine.isRunning)
        #expect(engine.duration == 50 * 60)
        #expect(store.activeTasks.count == 2)
    }

    @Test func errorsAreReadable() {
        let (_, _, commands) = make()
        _ = try? commands.run("add_task", ["title": "Paper A"])
        _ = try? commands.run("add_task", ["title": "Paper B"])
        #expect(throws: CommandError.self) { try commands.run("select_task", ["task": "paper"]) }
        #expect(throws: CommandError.self) { try commands.run("nope") }
        #expect(throws: CommandError.self) { try commands.run("report", ["period": "decade"]) }
    }

    @Test func manualIntervalNoteAndReport() throws {
        let (store, _, commands) = make()
        _ = try commands.run("add_task", ["title": "Thesis"])
        let start = CommandCenter.iso.string(from: Date().addingTimeInterval(-3600))
        _ = try commands.run("add_interval", ["task": "Thesis", "start": start, "minutes": 50])
        _ = try commands.run("add_note", ["note": "wrote 2 pages"])
        #expect(store.intervals.first?.note == "wrote 2 pages")
        let report = try commands.run("report", ["period": "today"]) as! [String: Any]
        #expect(report["completed_intervals"] as? Int == 1)
        #expect((report["by_task"] as? [[String: Any]])?.first?["task"] as? String == "Thesis")
    }

    @Test func goalChangesTodayOnly() throws {
        let (store, _, commands) = make()
        store.settings.weekdayTargets = Array(repeating: 8, count: 7)
        _ = try commands.run("set_goal", ["goal": "3"])
        #expect(store.todayTarget == 3)
        #expect(store.settings.weekdayTargets?.filter { $0 == 8 }.count == 6)
    }
}

@MainActor @Suite struct MCPTests {
    private func server() -> MCPServer {
        let store = Store(directory: tempDir())
        let engine = TimerEngine(store: store)
        engine.idleSeconds = { 0 }
        let commands = CommandCenter(store: store, engine: engine)
        return MCPServer { command, args in try MainActor.assumeIsolated { try commands.run(command, args) } }
    }

    @Test func handshakeAndToolList() throws {
        let s = server()
        let initialize = try #require(s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]]))
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = try #require(s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])
        let tools = try #require(list["tools"] as? [[String: Any]])
        #expect(tools.count == MCPServer.tools.count)
        #expect(tools.allSatisfy { JSONSerialization.isValidJSONObject($0) })
        // Every tool maps to a real command.
        #expect(MCPServer.tools.allSatisfy { CommandCenter.commands.contains($0.command) })
    }

    @Test func callToolsAndReportErrors() throws {
        let s = server()
        let added = try #require(s.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                           "params": ["name": "add_task", "arguments": ["title": "Thesis", "select": true]]])?["result"] as? [String: Any])
        #expect(added["isError"] as? Bool == false)
        let status = try #require(s.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                            "params": ["name": "get_status", "arguments": [:]]])?["result"] as? [String: Any])
        #expect((status["structuredContent"] as? [String: Any])?["task"] as? String == "Thesis")
        let failed = try #require(s.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                            "params": ["name": "complete_task", "arguments": ["task": "nothing like this"]]])?["result"] as? [String: Any])
        #expect(failed["isError"] as? Bool == true)
        let unknown = try #require(s.handle(["jsonrpc": "2.0", "id": 6, "method": "nope"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}

@MainActor @Suite struct SocketTests {
    @Test func roundTrip() async throws {
        let path = NSTemporaryDirectory() + "fk-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlSocket.Server(path: path) { command, args in
            if command == "fail" { throw CommandError("nope") }
            return ["echo": command, "n": args["n"] ?? 0]
        }
        try server.start()
        defer { server.stop() }
        let ok = try await Task.detached { try ControlSocket.send("ping", ["n": 7], path: path, launch: false) }.value
        #expect((ok as? [String: Any])?["echo"] as? String == "ping")
        #expect((ok as? [String: Any])?["n"] as? Int == 7)
        await #expect(throws: CommandError.self) {
            try await Task.detached { try ControlSocket.send("fail", path: path, launch: false) }.value
        }
    }
}

@MainActor @Suite struct SynthTests {
    @Test func rendersPlayableSounds() {
        for name in Synth.names {
            #expect(Synth.sound(named: name) != nil, "\(name)")
        }
        #expect(Synth.render("missing") == nil)
    }
}

@Suite struct AmbientTests {
    @Test func catalogIsWellFormed() {
        let ids = AmbientSource.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Only generated sounds ship; streams are user-supplied.
        #expect(AmbientSource.catalog.allSatisfy { $0.isGenerated || $0.kind == .off || $0.kind == .custom })
        #expect(AmbientSource.find("radio.somafm.fluid") == .off)
    }

    @Test func binauralEarsDifferByTheBeat() {
        var signal = Signal(kind: .binaural(carrier: 200, beat: 10), sampleRate: 44_100, bedLevel: 0)
        var crossings = (left: 0, right: 0)
        var previous = signal.next()
        for _ in 0..<44_100 {
            let s = signal.next()
            if (previous.left < 0) != (s.left < 0) { crossings.left += 1 }
            if (previous.right < 0) != (s.right < 0) { crossings.right += 1 }
            previous = s
        }
        // Two zero crossings per cycle over one second.
        #expect(abs(crossings.left - 400) <= 2)
        #expect(abs(crossings.right - 420) <= 2)
    }

    @Test func noiseStaysInRange() {
        for color in [NoiseColor.white, .pink, .brown] {
            var signal = Signal(kind: .noise(color))
            let peak = (0..<44_100).map { _ in abs(signal.next().left) }.max() ?? 0
            #expect(peak > 0.01 && peak <= 1, "\(color)")
        }
    }

    @Test func onlyRealTrackTitlesAreShown() {
        #expect(MetadataReader.trackTitle("Kupla - Valentine") == "Kupla - Valentine")
        #expect(MetadataReader.trackTitle("8163971") == nil)
        #expect(MetadataReader.trackTitle("ChillHop") == nil)
        #expect(MetadataReader.trackTitle(nil) == nil)
    }
}

@MainActor @Suite struct ImportTestsOtherApps {
    @Test func csvParserHandlesQuotesSemicolonsAndCRLF() {
        let rows = CSVImport.parse("a;b;c\r\n1;\"x; \"\"y\"\"\";3\r\n")
        #expect(rows == [["a", "b", "c"], ["1", "x; \"y\"", "3"]])
    }

    @Test func togglDetailedReport() throws {
        let csv = """
        User,Email,Client,Project,Task,Description,Billable,Start date,Start time,End date,End time,Duration,Tags
        Ana,a@example.com,,Thesis,,"Writing, ch. 3",No,2026-10-12,09:00:00,2026-10-12,09:50:00,00:50:00,
        """
        let file = try #require(CSVImport(text: csv))
        #expect(file.format == .toggl)
        let (records, failed) = file.records(source: "t")
        #expect(failed == 0)
        #expect(records.first?.task == "Thesis" && records.first?.note == "Writing, ch. 3")
        #expect(records.first?.duration == TimeInterval(3000))
    }

    @Test func clockifyWithUSDatesAndAMPM() throws {
        let csv = """
        Project,Client,Description,Task,User,Group,Email,Tags,Billable,Start Date,Start Time,End Date,End Time,Duration (h),Duration (decimal)
        Exam,,Practice,,Ana,,a@example.com,,No,10/13/2026,02:00:00 PM,10/13/2026,02:25:00 PM,00:25:00,0.42
        """
        let file = try #require(CSVImport(text: csv))
        #expect(file.format == .clockify)
        #expect(file.dayFirst == false && !file.dayOrderAmbiguous)
        let record = try #require(file.records(source: "c").records.first)
        #expect(Calendar.current.component(.hour, from: record.start) == 14)
        #expect(Calendar.current.component(.day, from: record.start) == 13)
        #expect(record.duration == TimeInterval(1500))
    }

    @Test func genericCSVIsMappedFromHeaderNames() throws {
        let file = try #require(CSVImport(text: "Started,Minutes,Category,Note\n18.10.2026 08:30,25,Reading,ch 8\n"))
        #expect(file.format == .genericCSV)
        #expect(file.dayFirst)
        let record = try #require(file.records(source: "g").records.first)
        #expect(record.task == "Reading" && record.note == "ch 8" && record.duration == TimeInterval(1500))
        #expect(Calendar.current.component(.month, from: record.start) == 10)
    }

    @Test func plumbExportRoundTripsAndReimportAddsNothing() throws {
        let source = Store(directory: tempDir())
        let task = source.addTask(title: "Thesis")
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(-86400))!
        source.addInterval(FocusInterval(taskID: task.id, phase: .work, start: start, duration: 3000, outcome: .completed))
        source.addInterval(FocusInterval(taskID: task.id, phase: .shortBreak, start: start.addingTimeInterval(3000), duration: 600, outcome: .completed))
        let file = try #require(CSVImport(text: CSVExport.csv(store: source)))
        #expect(file.format == .plumb)
        let records = file.records(source: "p").records
        #expect(records.map(\.phase) == [.work, .shortBreak])

        let target = Store(directory: tempDir())
        let first = ImportApplier.apply(records, to: target)
        #expect(first.intervals == 2 && first.newTasks == 1)
        #expect(target.intervals.first { $0.phase == .work }?.start == start)
        let again = ImportApplier.apply(records, to: target)
        #expect(again.intervals == 0)
        #expect(target.tasks.count == 1)
    }

    @Test func tomatoBarLog() {
        let log = """
        {"timestamp":1000,"type":"appstart"}
        {"event":"startStop","fromState":"idle","timestamp":1010,"toState":"work","type":"transition"}
        {"event":"timerFired","fromState":"work","timestamp":2510,"toState":"rest","type":"transition"}
        {"event":"skipRest","fromState":"rest","timestamp":2600,"toState":"work","type":"transition"}
        {"event":"startStop","fromState":"work","timestamp":3000,"toState":"idle","type":"transition"}
        """
        let records = TomatoBarImport.records(from: log)
        #expect(records.map(\.phase) == [.work, .shortBreak, .work])
        #expect(records.map(\.outcome) == [.completed, .skipped, .skipped])
        #expect(records.map(\.duration) == [1500, 90, 400])
    }
}

@Suite struct TranslationTests {
    /// Every literal passed to L(...) in the app's source.
    private func sourceKeys() throws -> [String] {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Plumb").standardized
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // Turn the Swift source form back into the runtime string.
                let raw = String(text[Range(match.range(at: 1), in: text)!])
                keys.append(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return keys
    }

    private func placeholders(_ s: String) -> [String] {
        s.components(separatedBy: "%%").joined().components(separatedBy: "%").dropFirst().map { String($0.prefix(1)) }
    }

    @Test func everyInterfaceTextHasAGermanTranslation() throws {
        let keys = try sourceKeys()
        #expect(keys.count > 300)
        let missing = Set(keys).filter { Translations.de[$0] == nil }.sorted()
        #expect(missing.isEmpty, "Missing German: \(missing)")
    }

    @Test func translationsKeepTheirPlaceholders() {
        for (english, german) in Translations.de {
            #expect(placeholders(english) == placeholders(german), "\(english) → \(german)")
            #expect(english.contains("%%") == german.contains("%%"), "\(english)")
        }
    }

    @Test func namesTranslatedFromRawValuesExist() {
        for tab in SettingsTab.allCases where tab != .sync {
            #expect(Translations.de[tab.rawValue] != nil, "\(tab)")
        }
        for period in ReportPeriod.allCases {
            #expect(Translations.de[period.rawValue] != nil, "\(period)")
        }
    }

    @Test func germanAndAmericanFormats() {
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 18, hour: 14, minute: 30).date!
        AppLanguage.$override.withValue(.de) {
            #expect(L("today %@", "3/8") == "heute 3/8")
            #expect(numberText(1.4) == "1,4")
            #expect(date.timeText == "14:30")
            #expect(date.dayMonthText == "18. Okt.")
            #expect(formatDuration(150 * 60) == "2 h 30 min")
        }
        AppLanguage.$override.withValue(.en) {
            #expect(L("today %@", "3/8") == "today 3/8")
            #expect(numberText(1.4) == "1.4")
            #expect(date.timeText.replacingOccurrences(of: "\u{202F}", with: " ") == "2:30 PM") // ICU uses a narrow no-break space
            #expect(date.dayMonthText == "Oct 18")
            #expect(formatDuration(150 * 60) == "2h 30m")
        }
    }
}

