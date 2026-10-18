import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        let services = Services.shared
        services.start()
        statusBar = StatusBarController(services: services)
        services.onTitleChange = { [weak self] in self?.statusBar?.refresh() }
        statusBar?.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Services.shared.stop()
        Services.shared.store.saveNow()
    }

    /// plumb:// links from the browser, Shortcuts, Raycast, Alfred, ...
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Services.shared.handle(url:))
    }

    /// Reopening the app from Finder or Spotlight shows the task list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Windows.shared.show(.tasks) }
        return true
    }

    /// A menu bar app has no visible menu, but text fields still need the
    /// standard key equivalents (copy, paste, undo, close window, quit).
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Plumb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc func openSettings() { Windows.shared.show(.settings) }
}

@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatusPanel()
    private let services: Services
    private var scrollMonitor: Any?

    init(services: Services) {
        self.services = services
        super.init()
        let root = TimerPopover(services: services).overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
        panel.contentViewController = NSHostingController(rootView: root)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .light)
        }
        Windows.shared.willShowWindow = { [weak self] in self?.panel.close() }
        services.showPanel = { [weak self] in self?.showPanel() }
        installScrollKnob()
    }

    func showPanel() {
        guard let button = item.button, !panel.isVisible else { return }
        panel.show(below: button)
    }

    /// Scrolling over the menu bar item turns the next interval's length, like a knob.
    private func installScrollKnob() {
        var travel: CGFloat = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.item.button?.window, event.window === window else { return event }
            let engine = self.services.engine
            guard engine.status == .idle else { return event }
            travel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
            while abs(travel) >= 1 {
                let step = travel > 0 ? 1 : -1
                engine.adjustIdleDuration(byMinutes: step)
                travel -= CGFloat(step)
            }
            self.refresh(forceTime: true)
            return nil
        }
    }

    func refresh(forceTime: Bool = false) {
        guard let button = item.button else { return }
        let engine = services.engine
        button.image = Self.lamp(engine.status, isBreak: engine.phase.isBreak)
        let showTime = forceTime || (services.store.settings.showTimerInMenuBar && engine.status != .idle)
        button.title = showTime ? " " + formatClock(engine.remaining) : ""
    }

    /// Menu bar glyph: a square lamp. Outline when idle, filled while running,
    /// half-filled when paused; breaks get a smaller square.
    private static func lamp(_ status: TimerStatus, isBreak: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let side: CGFloat = isBreak ? 8 : 10
            let rect = NSRect(x: (12 - side) / 2, y: (12 - side) / 2, width: side, height: side)
            NSColor.black.set()
            switch status {
            case .running:
                rect.fill()
            case .paused:
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                NSRect(x: rect.minX, y: rect.minY, width: side, height: side / 2).fill()
            case .idle:
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel.isVisible {
            panel.close()
        } else {
            panel.show(below: sender)
        }
    }

    /// Right click: quick controls without opening the panel.
    private func showMenu() {
        let engine = services.engine
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(engine.phase.label) · \(formatClock(engine.remaining)) · \(services.store.title(for: engine.taskID))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(action(engine.isRunning ? "Pause" : (engine.status == .paused ? "Resume" : "Start \(engine.phase.title)")) { engine.toggle() })
        menu.addItem(action("Skip \(engine.phase.title)") { engine.skip() })
        if engine.status != .idle { menu.addItem(action("Stop") { engine.stop() }) }
        menu.addItem(.separator())
        menu.addItem(action("Tasks…") { Windows.shared.show(.tasks) })
        menu.addItem(action("Reports…") { Windows.shared.show(.reports) })
        menu.addItem(action("Settings…") { Windows.shared.show(.settings) })
        menu.addItem(.separator())
        menu.addItem(action("Quit Plumb") { NSApp.terminate(nil) })
        if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
    }
}

/// Square, shadowless panel under the menu bar item. Closes when it loses focus
/// or on a click elsewhere, like a popover.
@MainActor
final class StatusPanel: NSPanel {
    private var outsideClickMonitor: Any?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hasShadow = false
        backgroundColor = TE.nsCanvas
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient]
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let view = contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        super.close()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

enum WindowKind: String {
    case tasks, reports, settings

    var title: String {
        switch self {
        case .tasks: "Plumb"
        case .reports: "Reports"
        case .settings: "Plumb Settings"
        }
    }

    var size: NSSize {
        switch self {
        case .tasks: NSSize(width: 820, height: 560)
        case .reports: NSSize(width: 860, height: 640)
        case .settings: NSSize(width: 620, height: 560)
        }
    }
}

/// Plain AppKit windows hosting SwiftUI views. The app shows a Dock icon only while
/// one of them is open, like a regular app, and goes back to menu-bar-only after.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    var willShowWindow: (() -> Void)?
    private var windows: [WindowKind: NSWindow] = [:]

    func show(_ kind: WindowKind) {
        willShowWindow?()
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ kind: WindowKind) -> NSWindow {
        let services = Services.shared
        let root: AnyView = switch kind {
        case .tasks: AnyView(TasksView(services: services))
        case .reports: AnyView(ReportsView(store: services.store))
        case .settings: AnyView(SettingsView(services: services))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: kind.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = kind.title
        window.titlebarAppearsTransparent = true
        window.backgroundColor = TE.nsCanvas
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(kind.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Plumb.\(kind.rawValue)")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            if !self.windows.values.contains(where: \.isVisible) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}
