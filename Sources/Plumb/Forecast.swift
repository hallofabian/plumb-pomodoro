import Foundation

/// Learns how far your estimates are off and forecasts when a task will be done.
///
/// Everything is measured in work time, expressed in intervals of the task's work
/// length: a 50-minute interval on a 25-minute task counts as 2, a skipped one as
/// what it lasted. So extended, shortened and mixed-length intervals add up honestly.
enum Forecast {
    /// How many completed tasks with an estimate are needed before calibrating.
    static let minimumSamples = 3
    /// Below these, a forecast is flagged as a rough guess.
    static let solidWeeks = 4
    static let solidTasks = 5

    struct Calibration: Equatable {
        /// Actual ÷ estimated work for each completed task with an estimate.
        var ratios: [Double]
        var median: Double

        /// The estimate corrected by the median ratio, e.g. 5 → 7 at 1.4×.
        func suggested(for estimate: Int) -> Int { max(1, Int((Double(estimate) * median).rounded(.up))) }
    }

    struct Result: Equatable {
        /// Intervals still needed: 10th, 50th and 90th percentile.
        var remaining: (low: Int, median: Int, high: Int)
        /// Finish dates: 10th, 50th and 90th percentile.
        var finish: (early: Date, median: Date, late: Date)
        /// Average work per week on this task over the sampled weeks, in intervals.
        var weeklyPace: Double
        var weeksSampled: Int
        /// Finished tasks whose estimate accuracy went into the forecast; 0 = uncalibrated.
        var tasksCalibrated: Int

        var calibrated: Bool { tasksCalibrated > 0 }
        /// Few weeks or few finished tasks behind it: the range is narrower than reality.
        var littleData: Bool { weeksSampled < solidWeeks || tasksCalibrated < solidTasks }

        static func == (a: Result, b: Result) -> Bool {
            a.remaining == b.remaining && a.finish == b.finish && a.weeklyPace == b.weeklyPace
                && a.weeksSampled == b.weeksSampled && a.tasksCalibrated == b.tasksCalibrated
        }
    }

    @MainActor
    static func calibration(store: Store) -> Calibration? {
        let ratios = store.completedTasks.compactMap { task -> Double? in
            guard let estimate = task.estimatedIntervals, estimate > 0 else { return nil }
            let actual = store.workedIntervals(for: task.id)
            return actual > 0 ? actual / Double(estimate) : nil
        }
        return calibration(ratios: ratios)
    }

    static func calibration(ratios: [Double]) -> Calibration? {
        guard ratios.count >= minimumSamples else { return nil }
        let sorted = ratios.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return Calibration(ratios: ratios, median: median)
    }

    /// Work per week on one task in intervals, oldest first, over up to `weeks` weeks
    /// ending this week and starting no earlier than the task's first interval.
    @MainActor
    static func weeklyWork(store: Store, taskID: UUID, weeks: Int = 12, now: Date = Date(),
                           calendar: Calendar = .current) -> [Double] {
        let unit = store.intervalLength(for: taskID)
        let work = store.intervals.filter { $0.taskID == taskID && $0.phase == .work }
        guard let first = work.map(\.start).min(),
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? thisWeek
        let span = (calendar.dateComponents([.weekOfYear], from: firstWeek, to: thisWeek).weekOfYear ?? 0) + 1
        let count = min(weeks, max(1, span))
        let start = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: thisWeek)!
        var counts = Array(repeating: 0.0, count: count)
        for i in work where i.start >= start {
            let index = calendar.dateComponents([.weekOfYear], from: start, to: i.start).weekOfYear ?? 0
            if index >= 0, index < count { counts[index] += i.duration / unit }
        }
        return counts
    }

    @MainActor
    static func run(store: Store, task: FocusTask, now: Date = Date()) -> Result? {
        guard let estimate = task.estimatedIntervals, estimate > 0 else { return nil }
        return run(done: store.workedIntervals(for: task.id), estimate: estimate,
                   ratios: calibration(store: store)?.ratios ?? [],
                   weeklyWork: weeklyWork(store: store, taskID: task.id, now: now),
                   from: now, seed: withUnsafeBytes(of: task.id.uuid) { $0.loadUnaligned(as: UInt64.self) })
    }

    /// Monte Carlo: each run draws an estimate-correction ratio from past tasks and
    /// replays randomly drawn past weeks until the remaining intervals are done.
    /// `done` and `weeklyWork` are in intervals of the task's work length.
    static func run(done: Double, estimate: Int, ratios: [Double], weeklyWork: [Double], from now: Date,
                    runs: Int = 2000, seed: UInt64 = 1) -> Result? {
        let pace = weeklyWork.isEmpty ? 0 : weeklyWork.reduce(0, +) / Double(weeklyWork.count)
        guard weeklyWork.reduce(0, +) >= 3, pace > 0 else { return nil }
        var rng = SplitMix64(seed: seed)
        var remainders: [Int] = []
        var days: [Double] = []
        for _ in 0..<runs {
            let ratio = ratios.isEmpty ? 1 : ratios[Int(rng.next() % UInt64(ratios.count))]
            // Under a minute or so left counts as done.
            let rest = Double(estimate) * ratio - done
            let remaining = rest < 0.05 ? 0 : rest
            remainders.append(Int(remaining.rounded(.up)))
            var left = remaining
            var weeks = 0.0
            while left > 0, weeks < 520 {
                let week = weeklyWork[Int(rng.next() % UInt64(weeklyWork.count))]
                if week >= left {
                    weeks += left / week
                    left = 0
                } else {
                    weeks += 1
                    left -= week
                }
            }
            days.append(weeks * 7)
        }
        remainders.sort()
        days.sort()
        func pick<T>(_ values: [T], _ q: Double) -> T { values[min(values.count - 1, Int(Double(values.count) * q))] }
        func date(_ d: Double) -> Date { now.addingTimeInterval(d * 86400) }
        return Result(
            remaining: (pick(remainders, 0.1), pick(remainders, 0.5), pick(remainders, 0.9)),
            finish: (date(pick(days, 0.1)), date(pick(days, 0.5)), date(pick(days, 0.9))),
            weeklyPace: pace, weeksSampled: weeklyWork.count, tasksCalibrated: ratios.count
        )
    }
}

/// Small deterministic generator so a forecast does not jump on every redraw.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
