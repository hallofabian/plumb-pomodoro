import AppKit

/// Blocks distracting apps and websites while a work interval runs.
///
/// Apps are hidden when they come to the front. Websites are checked in the
/// frontmost browser through Apple Events and redirected to a local page; macOS
/// asks once per browser for permission (Privacy & Security → Automation).
@MainActor
final class Blocker {
    private let store: Store
    private var active = false
    private var activationObserver: NSObjectProtocol?
    private var siteTimer: Timer?
    private var scripts: [String: NSAppleScript] = [:]
    private var lastNotice: [String: Date] = [:]
    private var deniedBrowsers: Set<String> = []

    /// Browsers that expose their tab URL to AppleScript, keyed by bundle id.
    static let browsers: [String: String] = [
        "com.apple.Safari": "current tab",
        "com.apple.SafariTechnologyPreview": "current tab",
        "com.google.Chrome": "active tab",
        "com.google.Chrome.beta": "active tab",
        "org.chromium.Chromium": "active tab",
        "com.brave.Browser": "active tab",
        "com.microsoft.edgemac": "active tab",
        "com.vivaldi.Vivaldi": "active tab",
        "company.thebrowser.Browser": "active tab",
        "com.operasoftware.Opera": "active tab",
    ]

    /// Never hidden, even in allow-list mode.
    private static let essentialApps: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.SystemSettings", "com.apple.Terminal",
        "com.apple.ActivityMonitor", "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]

    init(store: Store) {
        self.store = store
    }

    func setActive(_ shouldBeActive: Bool) {
        guard shouldBeActive != active else { return }
        active = shouldBeActive
        if active { begin() } else { end() }
    }

    private func begin() {
        writeBlockedPage()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.check(app) }
            }
        }
        for app in NSWorkspace.shared.runningApplications where isBlocked(app) { app.hide() }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontmostBrowser() }
        }
        RunLoop.main.add(timer, forMode: .common)
        siteTimer = timer
    }

    private func end() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        siteTimer?.invalidate()
        siteTimer = nil
    }

    // MARK: Apps

    private func check(_ app: NSRunningApplication) {
        guard isBlocked(app) else { return }
        app.hide()
        notice(key: app.bundleIdentifier ?? "", title: L("%@ is blocked", app.localizedName ?? "App"),
               body: L("You chose to block it during work intervals."))
    }

    func isBlocked(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !Self.essentialApps.contains(id) else { return false }
        let s = store.settings
        switch s.blockMode {
        case .blockList: return s.blockApps.contains { $0.bundleID == id }
        // Browsers stay usable in allow-list mode; their sites are filtered instead.
        case .allowList: return !s.allowApps.contains { $0.bundleID == id } && Self.browsers[id] == nil
        }
    }

    // MARK: Websites

    private func checkFrontmostBrowser() {
        let s = store.settings
        let sites = s.blockMode == .blockList ? s.blockSites : s.allowSites
        guard s.blockMode == .allowList || !sites.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              let tab = Self.browsers[id], !deniedBrowsers.contains(id) else { return }

        guard let url = run("tell application id \"\(id)\" to return URL of \(tab) of front window", cacheKey: id + ".get", browser: id),
              let host = URL(string: url)?.host?.lowercased(),
              url.hasPrefix("http") else { return }

        let matches = sites.contains { Self.host(host, matches: $0) }
        guard s.blockMode == .blockList ? matches : !matches else { return }

        let page = blockedPageURL.absoluteString + "?site=" + (host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        _ = run("tell application id \"\(id)\" to set URL of \(tab) of front window to \"\(page)\"", cacheKey: nil, browser: id)
        notice(key: host, title: L("%@ is blocked", "\(host)"), body: L("Back to work — it is available again during your break."))
    }

    nonisolated static func host(_ host: String, matches pattern: String) -> Bool {
        var p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        if let range = p.range(of: "://") { p = String(p[range.upperBound...]) }
        p = String(p.prefix { $0 != "/" })
        if p.hasPrefix("www.") { p.removeFirst(4) }
        guard !p.isEmpty else { return false }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h == p || h.hasSuffix("." + p)
    }

    private func run(_ source: String, cacheKey: String?, browser: String) -> String? {
        let script: NSAppleScript
        if let cacheKey, let cached = scripts[cacheKey] {
            script = cached
        } else {
            guard let new = NSAppleScript(source: source) else { return nil }
            if let cacheKey { scripts[cacheKey] = new }
            script = new
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -1743 {
            deniedBrowsers.insert(browser)
            notice(key: "denied." + browser, title: L("Website blocking needs permission"),
                   body: L("Allow Plumb to control your browser in System Settings → Privacy & Security → Automation."))
        }
        return result.stringValue
    }

    private var blockedPageURL: URL { Store.defaultDirectory.appendingPathComponent("blocked.html") }

    private func writeBlockedPage() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Blocked · Plumb</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 17px -apple-system, system-ui, sans-serif; display: grid; place-items: center; height: 100vh; margin: 0;
               background: Canvas; color: CanvasText; }
        main { text-align: center; max-width: 28rem; padding: 0 16px; }
        h1 { font-size: 28px; margin-bottom: 8px; }
        p { opacity: .7; }
        </style></head><body><main>
        <h1>Stay focused</h1>
        <p><strong id="site">This site</strong> is blocked during work intervals.<br>It opens again when your break starts.</p>
        </main><script>
        const s = new URLSearchParams(location.search).get('site'); if (s) document.getElementById('site').textContent = s;
        </script></body></html>
        """
        try? html.write(to: blockedPageURL, atomically: true, encoding: .utf8)
    }

    private func notice(key: String, title: String, body: String) {
        if let last = lastNotice[key], Date().timeIntervalSince(last) < 20 { return }
        lastNotice[key] = Date()
        Services.shared.notify(title: title, body: body)
    }
}
