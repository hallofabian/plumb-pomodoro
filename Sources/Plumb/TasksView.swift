import SwiftUI

/// Stand-in selection id for the built-in task "Other" (intervals with no task).
private let otherTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

private enum ListMode: Hashable { case today, todo, completed }

struct TasksView: View {
    let services: Services
    @State private var mode = ListMode.today
    @State private var search = ""
    @State private var newTask = ""
    @State private var selection: UUID?

    init(services: Services, selection: UUID? = nil) {
        self.services = services
        _selection = State(initialValue: selection)
        if selection != nil { _mode = State(initialValue: .todo) }
    }

    private var store: Store { services.store }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Rule(vertical: true)
                Group {
                    if let selection, selection == otherTaskID || store.task(selection) != nil {
                        TaskDetail(services: services, taskID: selection == otherTaskID ? nil : selection)
                            .id(selection)
                    } else if mode == .today {
                        TodayOverview(services: services)
                    } else {
                        VStack(alignment: .leading, spacing: TE.s1) {
                            Code("no task selected")
                            Text("Pick a task on the left to see its notes, estimate, forecast and history.")
                                .font(TE.body()).foregroundStyle(TE.inkSecondary)
                        }
                        .padding(TE.s3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            UndoBar(store: store)
        }
        .background(TE.canvas)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TE.s1) {
                TESegmented(selection: Binding(get: { mode }, set: { mode = $0; if $0 == .today { selection = nil } }),
                            options: [(.today, "today"), (.todo, "to do"), (.completed, "done")])
                TextField("", text: $search, prompt: Text("search").foregroundStyle(TE.inkMuted)).teField()
                if mode != .completed {
                    TextField("", text: $newTask, prompt: Text("new task, press return").foregroundStyle(TE.inkMuted))
                        .teField()
                        .onSubmit(addTask)
                }
            }
            .padding(TE.s2)
            Rule(strong: true)

            List {
                if mode == .todo, search.isEmpty, store.settings.showOtherTask {
                    row(nil)
                }
                switch mode {
                case .today:
                    ForEach(filtered(todayTasks)) { row($0) }
                case .todo:
                    ForEach(filtered(store.activeTasks)) { row($0) }
                        .onMove { if search.isEmpty { store.moveActiveTasks(from: $0, to: $1) } }
                case .completed:
                    ForEach(filtered(store.completedTasks)) { row($0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            // A fresh list per tab: reusing one List across very different row sets
            // leaves rows blank until the user scrolls (SwiftUI on macOS).
            .id(mode)
            .overlay(alignment: .topLeading) {
                if visibleTasks.isEmpty {
                    Code(emptyText)
                        .padding(TE.s2)
                        .padding(.top, mode == .todo && store.settings.showOtherTask ? 44 : 0)
                }
            }

            Rule()
            Code("\(store.activeTasks.count) open · \(store.completedTasks.count) done")
                .padding(.horizontal, TE.s2)
                .padding(.vertical, 10)
        }
    }

    /// Due today or overdue, plus anything worked on today.
    private var todayTasks: [FocusTask] {
        let endOfToday = Calendar.current.dateInterval(of: .day, for: Date())!.end
        let workedOn = Set(store.intervals(on: Date()).compactMap(\.taskID))
        return store.activeTasks.filter { ($0.dueDate.map { $0 < endOfToday } ?? false) || workedOn.contains($0.id) }
    }

    private var visibleTasks: [FocusTask] {
        switch mode {
        case .today: todayTasks
        case .todo: store.activeTasks
        case .completed: store.completedTasks
        }
    }

    private var emptyText: String {
        switch mode {
        case .today: "nothing due or worked on today"
        case .todo: "no tasks to do"
        case .completed: "no completed tasks yet"
        }
    }

    private func row(_ task: FocusTask?) -> some View {
        let id = task?.id ?? otherTaskID
        return TaskRow(services: services, task: task, selected: selection == id)
            .contentShape(Rectangle())
            .onTapGesture { selection = id }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func filtered(_ tasks: [FocusTask]) -> [FocusTask] {
        search.isEmpty ? tasks : tasks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func addTask() {
        let title = newTask.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var task = store.addTask(title: title)
        if mode == .today {
            task.dueDate = Calendar.current.startOfDay(for: Date())
            store.update(task)
        }
        selection = task.id
        newTask = ""
    }
}

/// "interval deleted · undo" until the next undoable change or ten seconds pass.
private struct UndoBar: View {
    let store: Store

    var body: some View {
        if let label = store.undoLabel {
            VStack(spacing: 0) {
                Rule(strong: true)
                HStack(spacing: TE.s2) {
                    Code(label, color: TE.ink)
                    Spacer()
                    Button("undo  ⌘Z") { store.undo() }
                        .teButton()
                        .keyboardShortcut("z", modifiers: .command)
                    Button("×") { store.clearUndo() }.teButton(.text).help("Dismiss")
                }
                .padding(.horizontal, TE.s2)
                .padding(.vertical, 8)
            }
            .background(TE.canvas)
            .task(id: label) {
                try? await Task.sleep(for: .seconds(10))
                if store.undoLabel == label { store.clearUndo() }
            }
        }
    }
}

/// Today at a glance: progress against the goal and a timeline of the day.
private struct TodayOverview: View {
    let services: Services

    var body: some View {
        let store = services.store
        let intervals = store.intervals(on: Date())
        let work = intervals.filter { $0.phase == .work }
        TEPage {
            VStack(alignment: .leading, spacing: TE.s1) {
                Code(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                HStack(alignment: .firstTextBaseline, spacing: TE.s3) {
                    Figure(label: "intervals", value: "\(store.todayWorkCount)/\(store.todayTarget)", size: 40)
                    Figure(label: "focused", value: formatDuration(work.reduce(0) { $0 + $1.duration }), size: 40)
                    Figure(label: "streak", value: "\(store.streak())d", size: 40)
                }
            }
            TESection(title: "timeline") {
                DayTimeline(intervals: intervals, now: services.engine.now).padding(.top, TE.s2)
            }
            TESection(title: "log") {
                if work.isEmpty {
                    Text("No work intervals yet today.").font(TE.body()).foregroundStyle(TE.inkSecondary).padding(.vertical, 10)
                }
                ForEach(work) { i in
                    HStack(alignment: .firstTextBaseline, spacing: TE.s2) {
                        Text(i.start.formatted(date: .omitted, time: .shortened)).font(TE.body(12).monospacedDigit())
                            .frame(width: 54, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.title(for: i.taskID)).font(TE.body())
                            if let note = i.note { Text(note).font(TE.body(12)).foregroundStyle(TE.inkSecondary) }
                        }
                        Spacer()
                        if i.outcome == .skipped { Code("skipped") }
                        Text(formatDuration(i.duration)).font(TE.body(12).monospacedDigit())
                    }
                    .foregroundStyle(TE.ink)
                    .padding(.vertical, 7)
                    Rule()
                }
            }
        }
    }
}

/// One day as a strip: work in ink, breaks as hairline outlines, now in amber.
struct DayTimeline: View {
    let intervals: [FocusInterval]
    let now: Date

    var body: some View {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        // Default window 07–22, widened to include anything recorded outside it.
        let firstHour = min(7, intervals.map { cal.component(.hour, from: $0.start) }.min() ?? 7)
        let lastHour = max(22, (intervals.map { cal.component(.hour, from: $0.end) }.max() ?? 21) + 1)
        let start = day.addingTimeInterval(TimeInterval(firstHour * 3600))
        let span = TimeInterval((lastHour - firstHour) * 3600)
        GeometryReader { geo in
            let x = { (d: Date) in CGFloat(d.timeIntervalSince(start) / span) * geo.size.width }
            ZStack(alignment: .topLeading) {
                Rule().frame(width: geo.size.width).offset(y: 31)
                ForEach(intervals) { i in
                    let w = max(1, x(i.end) - x(i.start))
                    Group {
                        if i.phase == .work {
                            Rectangle().fill(i.outcome == .completed ? TE.ink : TE.inkSecondary)
                        } else {
                            Rectangle().strokeBorder(TE.inkMuted, lineWidth: 1)
                        }
                    }
                    .frame(width: w, height: i.phase == .work ? 24 : 12)
                    .offset(x: x(i.start), y: i.phase == .work ? 8 : 20)
                    .help("\(i.phase.label) · \(i.start.formatted(date: .omitted, time: .shortened)) · \(formatDuration(i.duration))")
                }
                if now > start, now < start.addingTimeInterval(span) {
                    Rectangle().fill(TE.signal).frame(width: 2, height: 32).offset(x: x(now))
                }
                ForEach(Array(stride(from: firstHour, through: lastHour, by: 3)), id: \.self) { h in
                    let pos = CGFloat(h - firstHour) / CGFloat(lastHour - firstHour) * geo.size.width
                    VStack(alignment: .leading, spacing: 2) {
                        Rectangle().fill(TE.ink).frame(width: 1, height: 5)
                        Code(String(format: "%02d", h))
                    }
                    .offset(x: min(pos, geo.size.width - 14), y: 32)
                }
            }
        }
        .frame(height: 56)
    }
}

private struct TaskRow: View {
    let services: Services
    let task: FocusTask?
    let selected: Bool

    var body: some View {
        let store = services.store
        let engine = services.engine
        let id = task?.id
        let done = store.completedWorkCount(for: id)
        let fg = selected ? TE.canvas : TE.ink
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let task {
                    Button {
                        task.isCompleted ? store.setCompleted(task.id, false) : services.taskCompleted(task.id)
                    } label: {
                        TECheck(checked: task.isCompleted, inverted: selected)
                    }
                    .buttonStyle(.plain)
                    .help(task.isCompleted ? "Mark as not completed" : "Mark as completed")
                } else {
                    Code("—", color: selected ? TE.canvas : TE.inkSecondary).frame(width: 13)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(task?.title ?? "other").font(TE.body()).foregroundStyle(fg).lineLimit(1)
                        .strikethrough(task?.isCompleted == true, color: fg)
                    if let due = task?.dueDate, task?.isCompleted == false {
                        Code("due \(due.formatted(.dateTime.day().month(.abbreviated)))",
                             color: due < Calendar.current.startOfDay(for: Date()) ? TE.signal : (selected ? TE.canvas : TE.inkSecondary))
                    } else if task == nil {
                        Code("time without a task", color: selected ? TE.canvas : TE.inkSecondary)
                    }
                }
                Spacer(minLength: 4)
                if engine.taskID == id, engine.status != .idle { LED(on: engine.isRunning) }
                Text(task?.estimatedIntervals.map { "\(done)/\($0)" } ?? "\(done)")
                    .font(TE.body(12).monospacedDigit())
                    .foregroundStyle(selected ? TE.canvas : TE.inkSecondary)
            }
            .padding(.horizontal, TE.s2)
            .padding(.vertical, 9)
            Rule()
        }
        .background(selected ? TE.ink : Color.clear)
        .contextMenu {
            Button("Start Timer for This Task") {
                engine.select(taskID: id)
                if engine.phase != .work { engine.stop() }
                engine.start()
            }
            if let task {
                Button(task.isCompleted ? "Mark as Not Completed" : "Mark as Completed") {
                    task.isCompleted ? store.setCompleted(task.id, false) : services.taskCompleted(task.id)
                }
                Divider()
                Button("Delete Task", role: .destructive) {
                    if services.engine.taskID == task.id { services.engine.select(taskID: nil) }
                    services.store.deleteTask(task.id)
                }
            }
        }
    }
}

private struct TaskDetail: View {
    let services: Services
    let taskID: UUID?
    @State private var draft: FocusTask?

    private var store: Store { services.store }

    var body: some View {
        TEPage {
            if draft != nil {
                VStack(alignment: .leading, spacing: TE.s1) {
                    Code("task")
                    TextField("", text: binding(\.title, ""), prompt: Text("title")).teField(large: true)
                    TextField("", text: binding(\.note, ""), prompt: Text("notes").foregroundStyle(TE.inkMuted), axis: .vertical)
                        .lineLimit(3...8)
                        .teField()
                }
                TESection(title: "plan") {
                    TERow(label: "Estimated intervals", detail: estimateHint) {
                        HStack(spacing: TE.s1) {
                            if let suggestion = suggestedEstimate {
                                Button("use \(suggestion)") { draft?.estimatedIntervals = suggestion }.teButton(.text)
                            }
                            TEStepper(value: Binding(get: { draft?.estimatedIntervals ?? 0 },
                                                     set: { draft?.estimatedIntervals = $0 > 0 ? $0 : nil }),
                                      range: 0...999, zeroLabel: "none")
                        }
                    }
                    TEToggleRow(label: "Due date", isOn: Binding(
                        get: { draft?.dueDate != nil },
                        set: { draft?.dueDate = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                    if draft?.dueDate != nil {
                        TERow(label: "Due") {
                            DatePicker("", selection: Binding(get: { draft?.dueDate ?? Date() }, set: { draft?.dueDate = $0 }),
                                       displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                        }
                    }
                    TERow(label: "Work type", detail: "Sets this task's interval lengths.") {
                        TEMenu(selection: binding(\.workTypeID, nil), options:
                            [(nil, "default · \(store.settings.durations.work) min")]
                                + store.workTypes.map { (Optional($0.id), "\($0.name) · \($0.durations.work) min") })
                    }
                }
                if let task = draft, !task.isCompleted { ForecastSection(store: store, task: task) }
            } else {
                VStack(alignment: .leading, spacing: TE.s1) {
                    Code("task")
                    Text("other").font(TE.heading(26)).foregroundStyle(TE.ink)
                    Text("Intervals without a task, and intervals of deleted tasks.")
                        .font(TE.body()).foregroundStyle(TE.inkSecondary)
                }
            }

            HStack(spacing: TE.s1) {
                Button("start timer") {
                    services.engine.select(taskID: taskID)
                    if services.engine.phase != .work { services.engine.stop() }
                    services.engine.start()
                }
                .teButton(.primary)
                if let task = draft {
                    Button(task.isCompleted ? "mark as not completed" : "mark as completed") {
                        task.isCompleted ? store.setCompleted(task.id, false) : services.taskCompleted(task.id)
                        draft = store.task(task.id)
                    }
                    .teButton()
                }
            }

            IntervalList(store: store, taskID: taskID)
        }
        .onAppear { draft = store.task(taskID) }
        .onChange(of: draft) { _, new in if let new { store.update(new) } }
    }

    private var calibration: Forecast.Calibration? { Forecast.calibration(store: store) }

    private var suggestedEstimate: Int? {
        guard let estimate = draft?.estimatedIntervals, let c = calibration else { return nil }
        let s = c.suggested(for: estimate)
        return s == estimate ? nil : s
    }

    private var estimateHint: String? {
        guard let c = calibration else { return nil }
        return String(format: "You usually need %.1f× your estimate (%d finished tasks).", c.median, c.ratios.count)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<FocusTask, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { draft?[keyPath: keyPath] ?? fallback }, set: { draft?[keyPath: keyPath] = $0 })
    }
}

/// When the task will likely be done, from real pace and estimate accuracy.
private struct ForecastSection: View {
    let store: Store
    let task: FocusTask

    var body: some View {
        TESection(title: "forecast", note: note) {
            if let r = Forecast.run(store: store, task: task) {
                VStack(alignment: .leading, spacing: TE.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: TE.s3) {
                        Figure(label: "likely done", value: r.remaining.median == 0 ? "now" : short(r.finish.median), size: 40)
                        Figure(label: "intervals left", value: r.remaining.low == r.remaining.high
                               ? "\(r.remaining.median)" : "\(r.remaining.low)–\(r.remaining.high)", size: 40)
                        Figure(label: "pace / week", value: String(format: "%.1f", r.weeklyPace), size: 40)
                    }
                    if r.remaining.median > 0 { RangeStrip(result: r) }
                }
                .padding(.vertical, TE.s2)
            } else {
                Text(task.estimatedIntervals == nil
                     ? "Set an estimate above to see when this task will likely be done."
                     : "A forecast appears after at least 3 completed intervals on this task.")
                    .font(TE.body()).foregroundStyle(TE.inkSecondary)
                    .padding(.vertical, 10)
            }
        }
    }

    private var note: String? {
        guard let r = Forecast.run(store: store, task: task), r.remaining.median > 0 else { return nil }
        return "80% chance between \(short(r.finish.early)) and \(short(r.finish.late)). Based on your last \(r.weeksSampled) week\(r.weeksSampled == 1 ? "" : "s") on this task"
            + (r.calibrated ? " and how far your estimates were off before." : "; it gets sharper once 3 tasks with estimates are done.")
    }

    private func short(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated)) }
}

/// Today → 10th–90th percentile band with the median tick.
private struct RangeStrip: View {
    let result: Forecast.Result

    var body: some View {
        GeometryReader { geo in
            let now = Date()
            let total = max(1, result.finish.late.timeIntervalSince(now) * 1.1)
            let x = { (d: Date) in CGFloat(d.timeIntervalSince(now) / total) * geo.size.width }
            ZStack(alignment: .topLeading) {
                Rule().frame(width: geo.size.width).offset(y: 8)
                Rectangle().fill(TE.ink)
                    .frame(width: max(2, x(result.finish.late) - x(result.finish.early)), height: 4)
                    .offset(x: x(result.finish.early), y: 6)
                Rectangle().fill(TE.signal).frame(width: 2, height: 16).offset(x: x(result.finish.median))
                Code("today").offset(y: 20)
                Code(result.finish.median.formatted(.dateTime.day().month(.abbreviated)), color: TE.ink)
                    .offset(x: min(x(result.finish.median) - 10, geo.size.width - 50), y: 20)
            }
        }
        .frame(height: 34)
    }
}

private struct IntervalList: View {
    let store: Store
    let taskID: UUID?
    @State private var editing: FocusInterval?

    var body: some View {
        let work = store.intervals(for: taskID).filter { $0.phase == .work }
        let completed = work.filter { $0.outcome == .completed }
        let total = work.reduce(0) { $0 + $1.duration }
        TESection(title: "history", note: "Click an interval to edit it.") {
            HStack(alignment: .firstTextBaseline, spacing: TE.s3) {
                Figure(label: "intervals", value: "\(completed.count)")
                Figure(label: "time", value: formatDuration(total))
                Figure(label: "skipped", value: "\(work.count - completed.count)")
                Spacer()
                Button("add interval") {
                    editing = FocusInterval(taskID: taskID, phase: .work,
                                            start: Date().addingTimeInterval(-Double(store.durations(for: taskID).work * 60)),
                                            duration: Double(store.durations(for: taskID).work * 60), outcome: .completed)
                }
                .teButton()
            }
            .padding(.vertical, TE.s2)
            Rule()
            if work.isEmpty {
                Text("No work intervals yet.").font(TE.body()).foregroundStyle(TE.inkSecondary).padding(.vertical, 10)
            }
            ForEach(work.prefix(200)) { interval in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: TE.s2) {
                        Text(interval.start.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(TE.body(12).monospacedDigit())
                        Spacer()
                        if interval.outcome == .skipped { Code("skipped") }
                        Text(formatDuration(interval.duration)).font(TE.body(12).monospacedDigit()).frame(width: 60, alignment: .trailing)
                        Button { store.deleteInterval(interval.id) } label: { Text("×").font(TE.body(14)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(TE.inkSecondary)
                            .help("Delete interval (undo with ⌘Z)")
                    }
                    if let note = interval.note {
                        Text(note).font(TE.body(12)).foregroundStyle(TE.inkSecondary)
                    }
                }
                .foregroundStyle(TE.ink)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture { editing = interval }
                Rule()
            }
            if work.count > 200 {
                Code("latest 200 of \(work.count) · see reports for all").padding(.top, TE.s1)
            }
        }
        .sheet(item: $editing) { interval in
            IntervalEditor(store: store, interval: interval, isNew: store.interval(interval.id) == nil)
        }
    }
}

/// Add or correct an interval: task, start, length, outcome, note.
private struct IntervalEditor: View {
    let store: Store
    @State var interval: FocusInterval
    let isNew: Bool
    @State private var minutes: Int = 0
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    init(store: Store, interval: FocusInterval, isNew: Bool) {
        self.store = store
        _interval = State(initialValue: interval)
        self.isNew = isNew
        _minutes = State(initialValue: Int((interval.duration / 60).rounded()))
        _note = State(initialValue: interval.note ?? "")
    }

    private var problem: String? {
        if minutes <= 0 { return "The interval needs at least one minute." }
        if interval.start.addingTimeInterval(Double(minutes * 60)) > Date() { return "The interval must end before now." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TE.s3) {
                Code(isNew ? "add interval" : "edit interval")
                TESection(title: "interval") {
                    TERow(label: "Task") {
                        TEMenu(selection: $interval.taskID,
                               options: [(nil, "other")] + (store.activeTasks + store.completedTasks).map { (Optional($0.id), $0.title) })
                    }
                    TERow(label: "Start") {
                        DatePicker("", selection: $interval.start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    TERow(label: "Length") { TEStepper(value: $minutes, range: 1...300, unit: "min") }
                    TERow(label: "Outcome") {
                        TESegmented(selection: $interval.outcome, options: [(.completed, "completed"), (.skipped, "skipped")])
                            .frame(width: 200)
                    }
                }
                TextField("", text: $note, prompt: Text("note: what got done").foregroundStyle(TE.inkMuted)).teField()
                if let problem { Code(problem, color: TE.ink) }
            }
            .padding(TE.s3)
            Spacer(minLength: 0)
            Rule(strong: true)
            HStack(spacing: TE.s1) {
                if !isNew {
                    Button("delete") { store.deleteInterval(interval.id); dismiss() }.teButton(.text)
                }
                Spacer()
                Button("cancel") { dismiss() }.teButton().keyboardShortcut(.cancelAction)
                Button("save") { save() }.teButton(.primary).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
            .padding(TE.s2)
        }
        .frame(width: 480, height: 470)
        .background(TE.canvas)
    }

    private func save() {
        var saved = interval
        saved.duration = Double(minutes * 60)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.note = trimmed.isEmpty ? nil : trimmed
        if isNew { store.addInterval(saved) } else { store.update(saved) }
        dismiss()
    }
}

/// Small code label over a large thin figure.
struct Figure: View {
    let label: String
    let value: String
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Code(label)
            Text(value).font(TE.numeral(size)).foregroundStyle(TE.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}
