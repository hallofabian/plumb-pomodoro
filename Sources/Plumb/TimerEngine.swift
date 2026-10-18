import AppKit
import Observation

/// The work/break cycle. Time is always derived from wall-clock dates, so the
/// timer stays correct across sleep, app restarts and missed ticks.
@MainActor
@Observable
final class TimerEngine {
    private(set) var phase: Phase = .work
    private(set) var status: TimerStatus = .idle
    private(set) var duration: TimeInterval = 25 * 60
    private(set) var accumulated: TimeInterval = 0
    private(set) var runStartedAt: Date?
    private(set) var phaseStartedAt: Date?
    private(set) var lastPhaseEndedAt: Date?
    /// Completed work intervals in the current cycle (resets after a long break).
    private(set) var round = 0
    private(set) var taskID: UUID?
    private(set) var now = Date()
    /// Set when the timer paused itself because nobody touched the Mac; the
    /// moment the inactivity began. Cleared by `resolveAway`.
    private(set) var awaySince: Date?
    /// The work interval that just finished, for "+5 min" and the note prompt.
    private(set) var lastWorkIntervalID: UUID?

    /// Fired for things the rest of the app reacts to (sounds, automation, blocking).
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Fired on every tick and state change, for the menu bar title.
    @ObservationIgnored var onTick: (() -> Void)?

    enum Event {
        case started(Phase), paused(Phase), finished(Phase, Outcome), stateChanged, taskSelected, targetReached
        /// The timer paused itself, and later the user came back.
        case wentAway, cameBack
    }

    enum AwayChoice: String, CaseIterable {
        /// Count the time away as work and continue.
        case keep
        /// Ignore the time away and continue.
        case drop
        /// Finish the interval at the moment the inactivity began.
        case end
    }

    /// Source of the current time; replaced in tests.
    @ObservationIgnored var clock: () -> Date = Date.init
    /// Seconds since the last keyboard or mouse input; replaced in tests.
    @ObservationIgnored var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var announcedReturn = false

    init(store: Store) {
        self.store = store
        if let s = store.settings.timer {
            phase = s.phase
            status = s.status
            duration = s.duration
            accumulated = s.accumulated
            runStartedAt = s.runStartedAt
            phaseStartedAt = s.phaseStartedAt
            lastPhaseEndedAt = s.lastPhaseEndedAt
            round = s.round
            taskID = store.task(s.taskID) == nil ? nil : s.taskID
            awaySince = s.awaySince
            lastWorkIntervalID = s.lastWorkIntervalID
        } else {
            duration = planned(.work)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    var elapsed: TimeInterval { accumulated + (runStartedAt.map { now.timeIntervalSince($0) } ?? 0) }
    var remaining: TimeInterval { max(0, duration - elapsed) }
    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }
    var isRunning: Bool { status == .running }

    func planned(_ phase: Phase) -> TimeInterval {
        TimeInterval(store.durations(for: taskID).minutes(for: phase) * 60)
    }

    /// "+N min" is offered while working and for ten minutes after a work interval ended.
    var canExtend: Bool {
        if phase == .work { return status != .idle }
        guard let last = store.interval(lastWorkIntervalID) else { return false }
        return now.timeIntervalSince(last.end) < 10 * 60
    }

    // MARK: Controls

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard status != .running else { return }
        now = clock()
        awaySince = nil
        if status == .idle {
            if phase.isBreak, store.settings.skipBreakIfIdle, let ended = lastPhaseEndedAt,
               now.timeIntervalSince(ended) > planned(.longBreak) {
                // Away longer than a long break already: the break happened, start working.
                phase = .work
                round = 0
                duration = planned(.work)
            }
            accumulated = 0
            phaseStartedAt = now
        }
        runStartedAt = now
        status = .running
        onEvent?(.started(phase))
        changed()
    }

    func pause() {
        guard status == .running else { return }
        now = clock()
        accumulated = elapsed
        runStartedAt = nil
        status = .paused
        onEvent?(.paused(phase))
        changed()
    }

    /// Ends the current interval early and moves on to the next phase.
    func skip() {
        now = clock()
        if elapsed >= 1 { record(.skipped, duration: elapsed) }
        onEvent?(.finished(phase, .skipped))
        advance()
    }

    /// Abandons the current interval and resets to a fresh work interval.
    /// Work of at least a minute is kept in the history as skipped.
    func stop() {
        now = clock()
        if phase == .work, elapsed >= 60 { record(.skipped, duration: elapsed) }
        phase = .work
        resetPhase()
    }

    /// What `stop()` would keep, for labelling the button.
    var stopKeepsMinutes: Int? {
        phase == .work && elapsed >= 60 ? Int(elapsed / 60) : nil
    }

    func select(taskID: UUID?) {
        guard taskID != self.taskID else { return }
        self.taskID = taskID
        if status == .idle { duration = planned(phase) }
        onEvent?(.taskSelected)
        changed()
    }

    /// Re-reads durations from settings when nothing is running.
    func refreshIdleDuration() {
        guard status == .idle else { return }
        duration = planned(phase)
        changed()
    }

    /// Turns the "knob" before starting: changes the next interval's length only.
    func adjustIdleDuration(byMinutes delta: Int) {
        guard status == .idle else { return }
        duration = min(180 * 60, max(60, duration + TimeInterval(delta * 60)))
        changed()
    }

    /// "+N min" from a break, always available: reopens the work interval that
    /// just ended when possible, otherwise ends the break and starts N minutes of work.
    func keepWorking(minutes: Int) {
        now = clock()
        if canExtend {
            extend(minutes: minutes)
            return
        }
        guard phase.isBreak else { return }
        if elapsed >= 1 { record(.skipped, duration: elapsed) }
        onEvent?(.finished(phase, .skipped))
        phase = .work
        resetPhase()
        duration = TimeInterval(minutes * 60)
        start()
    }

    /// Adds minutes to the running work interval, or reopens the one that just
    /// ended so the extra time lands in the same interval.
    func extend(minutes: Int) {
        now = clock()
        guard canExtend else { return }
        let extra = TimeInterval(minutes * 60)
        if phase == .work {
            duration += extra
            changed()
            return
        }
        guard let last = store.interval(lastWorkIntervalID) else { return }
        store.discardInterval(last.id)
        phase = .work
        round = max(0, round - 1)
        taskID = last.taskID
        accumulated = last.duration
        duration = last.duration + extra
        phaseStartedAt = last.start
        runStartedAt = now
        status = .running
        lastWorkIntervalID = nil
        onEvent?(.started(.work))
        changed()
    }

    func resolveAway(_ choice: AwayChoice) {
        guard let since = awaySince else { return }
        now = clock()
        awaySince = nil
        switch choice {
        case .keep:
            accumulated = min(duration, accumulated + now.timeIntervalSince(since))
            start()
        case .drop:
            start()
        case .end:
            if accumulated >= 1 { record(.skipped, duration: accumulated) }
            onEvent?(.finished(.work, .skipped))
            advance()
        }
    }

    // MARK: Internals

    func tick() {
        now = clock()
        if status == .running, phase == .work, store.settings.awayDetection { checkAway() }
        if status == .paused, awaySince != nil, !announcedReturn, idleSeconds() < 5 {
            announcedReturn = true
            onEvent?(.cameBack)
        }
        if status == .running, elapsed >= duration { complete() }
        onTick?()
    }

    /// Pauses retroactively at the moment input stopped, if that was long enough ago
    /// and before the interval would have ended. Also covers sleeping through an interval.
    private func checkAway() {
        let idle = idleSeconds()
        guard idle >= TimeInterval(store.settings.awayMinutes * 60), let runStart = runStartedAt else { return }
        let since = max(runStart, now.addingTimeInterval(-idle))
        let workedUntilAway = accumulated + since.timeIntervalSince(runStart)
        guard workedUntilAway < duration else { return }
        accumulated = workedUntilAway
        runStartedAt = nil
        status = .paused
        awaySince = since
        announcedReturn = false
        onEvent?(.wentAway)
        changed()
    }

    private func complete() {
        // The Mac may have slept past the end; use the real end time, not now.
        let endedAt = (runStartedAt ?? now).addingTimeInterval(duration - accumulated)
        let id = record(.completed, duration: duration)
        let finished = phase
        if finished == .work {
            round += 1
            lastWorkIntervalID = id
            if store.todayWorkCount == store.todayTarget { onEvent?(.targetReached) }
        }
        onEvent?(.finished(finished, .completed))
        advance()
        lastPhaseEndedAt = endedAt
        if store.settings.autoStart { start() } else { changed() }
    }

    private func advance() {
        switch phase {
        case .work:
            let every = max(1, store.durations(for: taskID).longBreakAfter)
            phase = round > 0 && round % every == 0 ? .longBreak : .shortBreak
        case .longBreak:
            round = 0
            phase = .work
        case .shortBreak:
            phase = .work
        }
        lastPhaseEndedAt = now
        resetPhase()
    }

    private func resetPhase() {
        status = .idle
        accumulated = 0
        runStartedAt = nil
        phaseStartedAt = nil
        awaySince = nil
        duration = planned(phase)
        changed()
    }

    @discardableResult
    private func record(_ outcome: Outcome, duration: TimeInterval) -> UUID {
        let interval = FocusInterval(
            taskID: taskID, phase: phase, start: phaseStartedAt ?? now.addingTimeInterval(-duration),
            duration: duration.rounded(), outcome: outcome
        )
        store.addInterval(interval)
        return interval.id
    }

    private func changed() {
        store.settings.timer = TimerSnapshot(
            phase: phase, status: status, duration: duration, accumulated: accumulated,
            runStartedAt: runStartedAt, phaseStartedAt: phaseStartedAt, lastPhaseEndedAt: lastPhaseEndedAt,
            round: round, taskID: taskID, awaySince: awaySince, lastWorkIntervalID: lastWorkIntervalID
        )
        onEvent?(.stateChanged)
        onTick?()
    }
}
