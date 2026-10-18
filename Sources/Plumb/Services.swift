import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

/// Owns the long-lived objects and wires timer events to their side effects.
@MainActor
final class Services: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Services()

    let store: Store
    let engine: TimerEngine
    let sync: FolderSync
    let blocker: Blocker
    let commands: CommandCenter
    let ambient = AmbientPlayer()
    var onTitleChange: (() -> Void)?
    /// Opens the menu bar panel (set by the status bar controller).
    var showPanel: (() -> Void)?

    private var sleepAssertion: IOPMAssertionID?
    private var control: ControlSocket.Server?

    private enum Note {
        static let workDone = "WORK_DONE", away = "AWAY"
        static let extend = "EXTEND", note = "NOTE", keep = "KEEP", drop = "DROP", end = "END"
    }

    private override init() {
        Store.migrateLegacyDirectory()
        store = Store()
        engine = TimerEngine(store: store)
        sync = FolderSync(store: store)
        blocker = Blocker(store: store)
        var complete: ((UUID) -> Void)?
        commands = CommandCenter(store: store, engine: engine) { complete?($0) }
        super.init()
        complete = { [weak self] in self?.taskCompleted($0) }
    }

    func start() {
        store.onLocalLibraryChange = { [weak self] in self?.sync.scheduleSync() }
        engine.onEvent = { [weak self] in self?.handle($0) }
        engine.onTick = { [weak self] in self?.tick() }
        setUpNotifications()
        applyAppearance()
        firstRun()
        applyHotKeys()
        updateTimerDependents()
        sync.start()
        startControlSocket()
    }

    func stop() {
        control?.stop()
        ambient.stop()
    }

    // MARK: Timer side effects

    private func handle(_ event: TimerEngine.Event) {
        switch event {
        case .started(let phase):
            Automation.run(phase == .work ? .workStarted : .breakStarted, store.settings)
            if phase == .work { BreakOverlay.shared.hide() }
        case .paused(let phase):
            if phase == .work { Automation.run(.workPaused, store.settings) }
        case .finished(let phase, let outcome):
            Automation.run(phase == .work ? .workEnded : .breakEnded, store.settings)
            guard outcome == .completed else { break }
            playSound(phase == .work ? store.settings.workEndSound : store.settings.breakEndSound)
            if phase == .work {
                let long = engine.phase == .longBreak
                notify(title: long ? "Time for a long break" : "Time for a break",
                       body: "\(store.title(for: engine.taskID)) · today \(store.todayProgress). Reply to note what you did.",
                       category: Note.workDone,
                       info: ["interval": engine.lastWorkIntervalID?.uuidString ?? ""])
                if store.settings.breakScreen { BreakOverlay.shared.show(services: self) }
            } else {
                notify(title: "Break is over", body: "Ready for the next work interval.")
            }
        case .taskSelected:
            Automation.run(.taskSelected, store.settings)
        case .targetReached:
            let streak = store.streak()
            notify(title: "Goal reached",
                   body: "\(store.todayTarget) work intervals today." + (streak > 1 ? " Streak: \(streak) days." : ""))
        case .wentAway:
            Automation.run(.workPaused, store.settings)
        case .cameBack:
            let minutes = Int(Date().timeIntervalSince(engine.awaySince ?? Date()) / 60)
            notify(title: "Paused while you were away",
                   body: "\(minutes) min without input. Keep that time, drop it, or end the interval there.",
                   category: Note.away)
            showPanel?()
        case .stateChanged:
            updateTimerDependents()
            if engine.phase == .work, engine.status == .running { BreakOverlay.shared.hide() }
        }
    }

    func taskCompleted(_ id: UUID) {
        store.setCompleted(id, true)
        Automation.run(.taskCompleted, store.settings)
        if engine.taskID == id { engine.select(taskID: nil) }
    }

    private func tick() {
        onTitleChange?()
    }

    /// Things that depend on whether the timer runs: sleep prevention, blocking
    /// and background sound.
    func updateTimerDependents() {
        let s = store.settings
        ambient.update(play: engine.isRunning && (engine.phase == .work || s.ambientDuringBreaks),
                       sourceID: s.ambientSource, customURL: s.ambientCustomURL, volume: s.ambientVolume)
        let shouldHold = store.settings.preventSleep && engine.isRunning
        if shouldHold, sleepAssertion == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Plumb timer is running" as CFString, &id) == kIOReturnSuccess {
                sleepAssertion = id
            }
        } else if !shouldHold, let id = sleepAssertion {
            IOPMAssertionRelease(id)
            sleepAssertion = nil
        }
        blocker.setActive(store.settings.blockingEnabled && engine.isRunning && engine.phase == .work)
        onTitleChange?()
    }

    // MARK: Integrations

    private func startControlSocket() {
        let server = ControlSocket.Server { [weak self] command, args in
            guard let self else { throw CommandError("Plumb is shutting down.") }
            return try self.commands.run(command, args)
        }
        do {
            try server.start()
            control = server
        } catch {
            NSLog("Plumb: control socket unavailable: \(error.localizedDescription)")
        }
    }

    /// plumb://start?task=Thesis, plumb://note?text=..., plumb://open/reports
    func handle(url: URL) {
        guard url.scheme == "plumb", let host = url.host() else { return }
        var args: [String: Any] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            args[item.name] = item.value ?? ""
        }
        switch host {
        case "open":
            switch url.pathComponents.dropFirst().first {
            case "reports": Windows.shared.show(.reports)
            case "settings": Windows.shared.show(.settings)
            case "tasks": Windows.shared.show(.tasks)
            default: showPanel?()
            }
        case "add": _ = try? commands.run("add_task", args)
        case "note": _ = try? commands.run("add_note", args)
        case "done": _ = try? commands.run("complete_task", args)
        case "select": _ = try? commands.run("select_task", args)
        default:
            do { _ = try commands.run(host, args) } catch { notify(title: "Plumb link failed", body: error.localizedDescription) }
        }
    }

    // MARK: First run

    private func firstRun() {
        guard !store.settings.firstRunDone else { return }
        store.settings.firstRunDone = true
        // ⌃⌥⌘P start/pause, ⌃⌥⌘→ skip: unlikely to clash, easy to change.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        if store.settings.startPauseHotKey == nil {
            store.settings.startPauseHotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: mods, display: "⌃⌥⌘P")
        }
        if store.settings.skipHotKey == nil {
            store.settings.skipHotKey = HotKey(keyCode: UInt32(kVK_RightArrow), modifiers: mods, display: "⌃⌥⌘→")
        }
        guard store.intervals.isEmpty, FileManager.default.fileExists(atPath: BeFocusedImport.defaultFile.path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Bring over your Be Focused history?"
            alert.informativeText = "Plumb found Be Focused data on this Mac. Import its tasks, interval history and timer lengths? You can also do this later in Settings → sync & data."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { BeFocusedImport.runInteractive(store: self.store) }
        }
    }

    // MARK: Sounds & notifications

    static let systemSounds: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    func playSound(_ name: String, volume: Double? = nil) {
        guard !name.isEmpty, name != "None" else { return }
        let sound = Synth.names.contains(name) ? Synth.sound(named: name) : NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        guard let sound else { return }
        sound.volume = Float(volume ?? store.settings.soundVolume)
        sound.play()
    }

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let extend = UNNotificationAction(identifier: Note.extend, title: "+\(store.settings.extendMinutes) min")
        let note = UNTextInputNotificationAction(identifier: Note.note, title: "Note what you did",
                                                 textInputButtonTitle: "Save", textInputPlaceholder: "e.g. drafted section 3.2")
        let keep = UNNotificationAction(identifier: Note.keep, title: "Keep the time")
        let drop = UNNotificationAction(identifier: Note.drop, title: "Drop it, continue")
        let end = UNNotificationAction(identifier: Note.end, title: "End interval there")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Note.workDone, actions: [note, extend], intentIdentifiers: []),
            UNNotificationCategory(identifier: Note.away, actions: [keep, drop, end], intentIdentifiers: []),
        ])
    }

    func notify(title: String, body: String, category: String? = nil, info: [String: String] = [:]) {
        guard store.settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let interval = (response.notification.request.content.userInfo["interval"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            switch action {
            case Note.extend: self.engine.extend(minutes: self.store.settings.extendMinutes)
            case Note.note: if let text, let interval { self.store.setNote(text, for: interval) }
            case Note.keep: self.engine.resolveAway(.keep)
            case Note.drop: self.engine.resolveAway(.drop)
            case Note.end: self.engine.resolveAway(.end)
            default: self.showPanel?()
            }
            completionHandler()
        }
    }

    // MARK: Settings side effects

    func applyAppearance() {
        switch store.settings.appearance {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func applyHotKeys() {
        HotKeyCenter.shared.register(id: 1, hotKey: store.settings.startPauseHotKey) { [weak self] in self?.engine.toggle() }
        HotKeyCenter.shared.register(id: 2, hotKey: store.settings.skipHotKey) { [weak self] in self?.engine.skip() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not change the login item"
                alert.runModal()
            }
        }
    }
}

enum Automation {
    /// Runs the Shortcuts shortcut the user assigned to `event`, if any.
    static func run(_ event: AutomationEvent, _ settings: AppSettings) {
        guard let name = settings.shortcuts[event.rawValue]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        runShortcut(named: name)
    }

    static func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
