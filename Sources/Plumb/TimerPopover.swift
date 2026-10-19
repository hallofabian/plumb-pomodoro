import SwiftUI

/// Content of the menu bar panel.
///
/// Keys: space start/pause · s skip · e extend · ↑↓ change task · n new task.
struct TimerPopover: View {
    let services: Services
    @State private var newTask = ""
    @State private var note = ""
    @FocusState private var focus: Field?

    private enum Field { case panel, newTask, note }

    private var engine: TimerEngine { services.engine }
    private var store: Store { services.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.awaySince != nil {
                awayBanner.padding(TE.s3)
                Rule(strong: true)
            }
            readout.padding(TE.s3)
            if let last = notePromptInterval {
                Rule()
                notePrompt(last).padding(TE.s3)
            }
            Rule()
            taskArea.padding(TE.s3)
            Rule()
            controls.padding(TE.s3)
            Rule(strong: true)
            footer
                .padding(.horizontal, TE.s3)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 320)
        .fixedSize()
        .background(TE.canvas)
        .focusable()
        .focused($focus, equals: .panel)
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
        .onAppear { focus = .panel }
    }

    // MARK: Sections

    private var awayBanner: some View {
        let since = engine.awaySince ?? Date()
        let minutes = max(1, Int(engine.now.timeIntervalSince(since) / 60))
        return VStack(alignment: .leading, spacing: TE.s1) {
            HStack(spacing: 6) {
                LED(on: true)
                Code(L("paused · no input"), color: TE.ink)
            }
            Text(L("No input since %@, %@ min ago. What should happen with that time?", since.timeText, "\(minutes)"))
                .font(TE.body())
                .foregroundStyle(TE.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TE.s1) {
                Button(L("keep it")) { engine.resolveAway(.keep) }.teButton(.primary)
                    .help(L("Count the %@ min as work and continue (space)", "\(minutes)"))
                Button(L("drop it")) { engine.resolveAway(.drop) }.teButton()
                    .help(L("Ignore the time away and continue"))
                Button(L("end there")) { engine.resolveAway(.end) }.teButton()
                    .help(L("Finish the interval at %@", since.timeText))
            }
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: TE.s2) {
            HStack(spacing: 6) {
                Code(engine.phase.label, color: TE.ink)
                Spacer()
                LED(on: engine.isRunning)
                Code(statusLabel)
                if engine.status == .idle {
                    SquareStep("−", label: L("Shorter next interval (or scroll on the menu bar icon)")) { engine.adjustIdleDuration(byMinutes: -1) }
                        .help(L("Shorter next interval (or scroll on the menu bar icon)"))
                    SquareStep("+", label: L("Longer next interval (or scroll on the menu bar icon)")) { engine.adjustIdleDuration(byMinutes: 1) }
                        .help(L("Longer next interval (or scroll on the menu bar icon)"))
                }
            }
            Text(formatClock(engine.remaining))
                .accessibilityLabel(L("%@ remaining", spokenDuration(engine.remaining)))
                .font(TE.numeral(72))
                .foregroundStyle(engine.status == .paused ? TE.inkSecondary : TE.ink)
                .padding(.leading, -4)
                .padding(.vertical, -8)
            ProgressBar(value: engine.progress, live: engine.isRunning)
            HStack(spacing: TE.s2) {
                RoundMeter(done: roundDone, total: roundTotal)
                Spacer()
                DailyGoal(services: services)
            }
        }
    }

    private func notePrompt(_ interval: FocusInterval) -> some View {
        VStack(alignment: .leading, spacing: TE.s1) {
            Code(L("what did you get done? · %@", "\(store.title(for: interval.taskID))"))
            TextField("", text: $note, prompt: Text(L("one line, then return")).foregroundStyle(TE.inkSecondary))
                .teField()
                .focused($focus, equals: .note)
                .onSubmit {
                    store.setNote(note, for: interval.id)
                    note = ""
                    focus = .panel
                }
        }
    }

    private var taskArea: some View {
        VStack(alignment: .leading, spacing: TE.s1) {
            Code(L("task"))
            TEMenu(selection: Binding(get: { engine.taskID }, set: { engine.select(taskID: $0) }),
                   options: taskOptions, minWidth: 274)
            TextField("", text: $newTask, prompt: Text(L("add a task and press return")).foregroundStyle(TE.inkSecondary))
                .teField()
                .focused($focus, equals: .newTask)
                .onSubmit(addTask)
            HStack(spacing: TE.s1) {
                Code(L("sound"))
                if services.ambient.state == .playing { LED(on: true, size: 6) }
                Spacer()
                TEMenu(selection: Binding(get: { store.settings.ambientSource },
                                          set: { store.settings.ambientSource = $0; services.updateTimerDependents() }),
                       options: AmbientSource.catalog.filter { $0.kind != .custom || store.settings.ambientCustomURL != nil }
                           .map { ($0.id, $0.name) },
                       minWidth: 160)
            }
            .padding(.top, 6)
            if let title = services.ambient.nowPlaying {
                Code(title).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: TE.s1) {
            Button(primaryTitle, action: engine.toggle)
                .teButton(.primary, expand: true)
            if engine.canExtend || engine.phase.isBreak {
                Button("+" + String(store.settings.extendMinutes)) { engine.keepWorking(minutes: store.settings.extendMinutes) }
                    .teButton()
                    .help(engine.phase == .work ? L("Add %@ min to this interval", "\(store.settings.extendMinutes)")
                          : engine.canExtend ? L("Reopen the interval that just ended and add %@ min", "\(store.settings.extendMinutes)")
                          : L("End the break and work %@ more min", "\(store.settings.extendMinutes)"))
            }
            Button(L("skip"), action: engine.skip)
                .teButton()
                .fixedSize()
                .help(engine.phase == .work ? L("End this work interval now, keep it as skipped, and go to the break")
                      : L("End the break now and go to work"))
            Button(L("reset"), action: engine.stop)
                .teButton()
                .fixedSize()
                .disabled(engine.status == .idle)
                .help(engine.stopKeepsMinutes.map { L("Reset to a fresh work interval; keeps %@ min as skipped", "\($0)") }
                      ?? L("Reset to a fresh work interval; under a minute is not kept"))
        }
    }

    private var footer: some View {
        HStack(spacing: TE.s2) {
            Button(L("tasks")) { Windows.shared.show(.tasks) }.teButton(.text).fixedSize()
            Button(L("reports")) { Windows.shared.show(.reports) }.teButton(.text).fixedSize()
            Button(L("settings")) { Windows.shared.show(.settings) }.teButton(.text).fixedSize()
            Spacer(minLength: 4)
            SyncMark(sync: services.sync)
            Button(L("quit")) { NSApp.terminate(nil) }.teButton(.text).fixedSize()
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard focus == .panel else { return .ignored }
        switch press.key {
        case .space: engine.toggle()
        case .upArrow: moveTask(-1)
        case .downArrow: moveTask(1)
        default:
            switch press.characters {
            case "s": engine.skip()
            case "e", "+": engine.phase.isBreak ? engine.keepWorking(minutes: store.settings.extendMinutes)
                                                : engine.extend(minutes: store.settings.extendMinutes)
            case "n": focus = .newTask
            default: return .ignored
            }
        }
        return .handled
    }

    private func moveTask(_ step: Int) {
        let ids = taskOptions.map(\.0)
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: engine.taskID) ?? 0
        engine.select(taskID: ids[(index + step + ids.count) % ids.count])
    }

    // MARK: Derived

    /// The just-finished work interval, if it has no note yet (for 30 minutes).
    private var notePromptInterval: FocusInterval? {
        guard engine.phase.isBreak, let last = store.interval(engine.lastWorkIntervalID), last.note == nil,
              engine.now.timeIntervalSince(last.end) < 30 * 60 else { return nil }
        return last
    }

    private var taskOptions: [(UUID?, String)] {
        var options: [(UUID?, String)] = []
        if store.settings.showOtherTask || engine.taskID == nil { options.append((nil, "other")) }
        options += store.activeTasks.map { (Optional($0.id), $0.title) }
        return options
    }

    private var roundTotal: Int { max(1, store.durations(for: engine.taskID).longBreakAfter) }

    private var roundDone: Int {
        if engine.phase == .longBreak { return roundTotal }
        return engine.round % roundTotal
    }

    private var primaryTitle: String {
        switch engine.status {
        case .running: L("pause")
        case .paused: L("resume")
        case .idle: engine.phase == .work ? L("start work") : L("start break")
        }
    }

    private var statusLabel: String {
        switch engine.status {
        case .running: L("running")
        case .paused: engine.awaySince != nil ? L("no input") : L("paused")
        case .idle: L("%@ min", "\(Int(engine.duration / 60))")
        }
    }

    private func addTask() {
        let title = newTask.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let task = store.addTask(title: title)
        engine.select(taskID: task.id)
        newTask = ""
        focus = .panel
    }
}

/// 16 pt square button with a single glyph.
struct SquareStep: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(TE.body(11))
                .frame(width: 16, height: 16)
                .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TE.ink)
        .accessibilityLabel(label)
    }
}

/// Compact sync indicator for the panel footer: "↻ 14:02", or an amber lamp on
/// error. Details on hover; a click opens the sync settings.
private struct SyncMark: View {
    let sync: FolderSync

    var body: some View {
        if sync.folderURL != nil {
            HStack(spacing: 3) {
                if sync.lastError != nil {
                    LED(on: true, size: 6)
                    Code(L("sync"), color: TE.ink)
                } else {
                    Code("↻ " + (sync.lastSync?.timeText ?? "…"))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .help(helpText)
            .onTapGesture { Windows.shared.show(.settings) }
        }
    }

    private var helpText: String {
        if let error = sync.lastError { return L("Sync failed: %@", error) }
        let when = sync.lastSync.map { L("Last synced %@", $0.timeText) } ?? L("Syncing")
        return "\(when) · \(sync.folderURL?.path ?? "")"
    }
}

/// Hairline track with a solid ink fill and an amber tip while running.
private struct ProgressBar: View {
    let value: Double
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rule().frame(width: geo.size.width)
                Rectangle().fill(TE.ink).frame(width: geo.size.width * value, height: 3)
                if live {
                    Rectangle().fill(TE.signal).frame(width: 3, height: 9)
                        .offset(x: max(0, geo.size.width * value - 3))
                }
            }
            .frame(height: 9)
            .animation(.linear(duration: 0.3), value: value)
        }
        .frame(height: 9)
        .accessibilityElement()
        .accessibilityLabel(L("Progress"))
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.locale)))
    }
}

/// One square per work interval in the cycle; filled squares are done.
private struct RoundMeter: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Code(L("to long break"))
            ForEach(0..<total, id: \.self) { i in
                Rectangle()
                    .fill(i < done ? TE.ink : Color.clear)
                    .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
        }
        .help(L("%@ of %@ work intervals until the long break", "\(done)", "\(total)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@ of %@ work intervals until the long break", "\(done)", "\(total)"))
    }
}

/// "today 3/8 · 5d" with square buttons to change today's goal in place.
private struct DailyGoal: View {
    let services: Services

    var body: some View {
        let store = services.store
        let target = store.todayTarget
        let streak = store.streak()
        HStack(spacing: 4) {
            Code(L("today %@", "\(store.todayProgress)"),
                 color: store.todayWorkCount >= target ? TE.ink : TE.inkSecondary)
            SquareStep("−", label: L("Lower today's goal")) { services.commands.setTodayGoal(max(1, target - 1)) }.disabled(target <= 1)
            SquareStep("+", label: L("Raise today's goal")) { services.commands.setTodayGoal(min(30, target + 1)) }.disabled(target >= 30)
            if streak > 1 {
                Code("· " + L("streak %@", "\(streak)"), color: TE.ink).help(L("%@ days in a row at goal", "\(streak)"))
            }
        }
        .help(L("Today's goal: %@ work intervals", "\(target)"))
    }
}
