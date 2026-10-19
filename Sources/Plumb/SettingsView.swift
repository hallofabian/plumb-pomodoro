import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable {
    case general, intervals, sounds, blocking, automation, integrations, sync

    var title: String { self == .sync ? L("sync & data") : L(rawValue) }
}

struct SettingsView: View {
    let services: Services
    @State private var tab: SettingsTab

    init(services: Services, tab: SettingsTab = .general) {
        self.services = services
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.title)
                            .font(TE.body())
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(tab == item ? TE.canvas : TE.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(tab == item ? TE.ink : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, TE.s3)
            .padding(.vertical, 10)
            Rule(strong: true)
            Group {
                switch tab {
                case .general: GeneralSettings(services: services)
                case .intervals: IntervalSettings(services: services)
                case .sounds: SoundSettings(services: services)
                case .blocking: BlockingSettings(services: services)
                case .automation: AutomationSettings(services: services)
                case .integrations: IntegrationSettings()
                case .sync: SyncSettings(services: services)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(TE.canvas)
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// Two-way binding into `store.settings`.
@MainActor
private func setting<T>(_ store: Store, _ keyPath: WritableKeyPath<AppSettings, T>, then: (() -> Void)? = nil) -> Binding<T> {
    Binding(get: { store.settings[keyPath: keyPath] }, set: { store.settings[keyPath: keyPath] = $0; then?() })
}

private struct GeneralSettings: View {
    let services: Services
    @State private var launchAtLogin = false

    var body: some View {
        let store = services.store
        TEPage {
            TESection(title: L("app")) {
                TEToggleRow(label: L("Launch at login"), isOn: Binding(get: { launchAtLogin }, set: {
                    services.launchAtLogin = $0
                    launchAtLogin = services.launchAtLogin
                }))
                TEToggleRow(label: L("Remaining time in the menu bar"),
                            isOn: setting(store, \.showTimerInMenuBar) { services.updateTimerDependents() })
                TERow(label: L("Appearance")) {
                    TESegmented(selection: setting(store, \.appearance) { services.applyAppearance() },
                                options: [(0, L("auto")), (1, L("light")), (2, L("dark"))])
                        .frame(width: 210)
                }
                TERow(label: L("Language"), detail: store.settings.language == AppLanguage.preference ? nil : L("Takes effect after a restart.")) {
                    HStack(spacing: TE.s1) {
                        if store.settings.language != AppLanguage.preference {
                            Button(L("restart now")) { Services.relaunch() }.teButton(.text)
                        }
                        TESegmented(selection: setting(store, \.language),
                                    options: [("system", L("system")), ("en", "English"), ("de", "Deutsch")])
                            .frame(width: 250)
                    }
                }
            }
            TESection(title: L("timer")) {
                TEToggleRow(label: L("Start the next interval automatically"), isOn: setting(store, \.autoStart))
                TEToggleRow(label: L("Skip break if idle"),
                            detail: L("Back after more than a long break? Start work instead of the pending break."),
                            isOn: setting(store, \.skipBreakIfIdle))
                TEToggleRow(label: L("Show task “other”"), isOn: setting(store, \.showOtherTask))
                TEToggleRow(label: L("Keep the Mac awake while the timer runs"),
                            isOn: setting(store, \.preventSleep) { services.updateTimerDependents() })
                TEToggleRow(label: L("Notifications"), isOn: setting(store, \.notificationsEnabled))
                TEToggleRow(label: L("Full-screen break card"),
                            detail: L("When a work interval ends, cover the screens with a card that asks you to step away."),
                            isOn: setting(store, \.breakScreen))
                TERow(label: L("Extend button adds")) { TEStepper(value: setting(store, \.extendMinutes), range: 1...30, unit: L("min")) }
            }
            TESection(title: L("honest time"),
                      note: L("Without keyboard or mouse input, the timer pauses at the moment input stopped and asks when you're back: keep that time, drop it, or end the interval there. No input is not the same as no work: reading, thinking and writing by hand count too, so keeping the time is the default (space). Set the time above your usual stretches away from the keyboard. This also catches a Mac that slept through an interval.")) {
                TEToggleRow(label: L("Pause when there's no input"), isOn: setting(store, \.awayDetection))
                TERow(label: L("No input for")) {
                    TEStepper(value: setting(store, \.awayMinutes), range: 1...30, unit: "min")
                }
                .disabled(!store.settings.awayDetection)
                .opacity(store.settings.awayDetection ? 1 : 0.4)
            }
            TESection(title: L("global shortcuts"),
                      note: L("Right-click the menu bar icon to start, pause or skip without opening the panel.")) {
                TERow(label: L("Start / pause")) {
                    HotKeyRecorder(hotKey: setting(store, \.startPauseHotKey)) { services.applyHotKeys() }
                }
                TERow(label: L("Skip interval")) {
                    HotKeyRecorder(hotKey: setting(store, \.skipHotKey)) { services.applyHotKeys() }
                }
            }
        }
        .onAppear { launchAtLogin = services.launchAtLogin }
    }
}

private struct IntervalSettings: View {
    let services: Services
    @State private var editing: WorkType?

    var body: some View {
        let store = services.store
        TEPage {
            TESection(title: L("daily goal"),
                      note: L("Shown as “today 3/%@” in the menu bar panel, where − and + change today's goal. Reaching it shows a notification and extends your streak; a goal of 0 makes a rest day that doesn't break it.", "\(store.todayTarget)")) {
                TEToggleRow(label: L("Different goal per weekday"), isOn: Binding(
                    get: { store.settings.weekdayTargets != nil },
                    set: { store.settings.weekdayTargets = $0 ? Array(repeating: store.settings.dailyTarget, count: 7) : nil }))
                if let targets = store.settings.weekdayTargets, targets.count == 7 {
                    // Monday first, stored Sunday first.
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { index in
                        TERow(label: AppLanguage.calendar.weekdaySymbols[index]) {
                            TEStepper(value: Binding(get: { store.settings.weekdayTargets?[index] ?? 0 },
                                                     set: { store.settings.weekdayTargets?[index] = $0 }),
                                      range: 0...30, zeroLabel: "rest")
                        }
                    }
                } else {
                    TERow(label: L("Work intervals per day")) {
                        TEStepper(value: setting(store, \.dailyTarget), range: 1...30)
                    }
                }
            }
            TESection(title: L("default intervals")) {
                DurationRows(durations: setting(store, \.durations) { services.engine.refreshIdleDuration() })
            }
            TESection(title: L("work types"),
                      note: L("Give a task its own lengths, e.g. 50/10, by picking a work type in the task list.")) {
                ForEach(store.workTypes) { type in
                    TERow(label: type.name,
                          detail: L("%@ min work · %@/%@ min breaks · long break after %@", "\(type.durations.work)", "\(type.durations.shortBreak)", "\(type.durations.longBreak)", "\(type.durations.longBreakAfter)")) {
                        HStack(spacing: TE.s2) {
                            Button(L("edit")) { editing = type }.teButton(.text)
                            Button(L("delete")) { confirmDelete(type) }.teButton(.text)
                        }
                    }
                }
                Button(L("add work type")) { editing = WorkType(name: "", durations: store.settings.durations) }
                    .teButton()
                    .padding(.top, TE.s2)
            }
        }
        .sheet(item: $editing) { type in
            WorkTypeEditor(type: type) { saved in
                store.save(saved)
                services.engine.refreshIdleDuration()
            }
        }
    }

    private func confirmDelete(_ type: WorkType) {
        let alert = NSAlert()
        alert.messageText = L("Delete the work type “%@”?", "\(type.name)")
        alert.informativeText = L("Tasks using it go back to the default intervals.")
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { services.store.deleteWorkType(type.id) }
    }
}

private struct DurationRows: View {
    @Binding var durations: Durations

    var body: some View {
        TERow(label: L("Work interval")) { TEStepper(value: $durations.work, range: 1...180, unit: L("min")) }
        TERow(label: L("Short break")) { TEStepper(value: $durations.shortBreak, range: 1...60, unit: L("min")) }
        TERow(label: L("Long break")) { TEStepper(value: $durations.longBreak, range: 1...120, unit: L("min")) }
        TERow(label: L("Long break after")) { TEStepper(value: $durations.longBreakAfter, range: 1...12, unit: L("intervals")) }
    }
}

private struct WorkTypeEditor: View {
    @State var type: WorkType
    let onSave: (WorkType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TE.s3) {
                VStack(alignment: .leading, spacing: TE.s1) {
                    Code(L("work type"))
                    TextField("", text: $type.name, prompt: Text(L("name, e.g. 50/10"))).teField(large: true)
                }
                TESection(title: L("intervals")) { DurationRows(durations: $type.durations) }
            }
            .padding(TE.s3)
            Spacer(minLength: 0)
            Rule(strong: true)
            HStack(spacing: TE.s1) {
                Spacer()
                Button(L("cancel")) { dismiss() }.teButton().keyboardShortcut(.cancelAction)
                Button(L("save")) { onSave(type); dismiss() }
                    .teButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(type.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(TE.s2)
        }
        .frame(width: 440, height: 400)
        .background(TE.canvas)
    }
}

private struct SoundSettings: View {
    let services: Services

    var body: some View {
        let store = services.store
        TEPage {
            TESection(title: L("interval end")) {
                SoundRow(title: L("Work completed"), selection: setting(store, \.workEndSound), services: services)
                SoundRow(title: L("Break ended"), selection: setting(store, \.breakEndSound), services: services)
                TERow(label: L("Volume")) { TESlider(value: setting(store, \.soundVolume)) }
            }
            AmbientSection(services: services)
        }
    }
}

private struct SoundRow: View {
    let title: String
    @Binding var selection: String
    let services: Services

    var body: some View {
        TERow(label: title) {
            HStack(spacing: TE.s1) {
                TEMenu(selection: $selection,
                       options: [("None", L("none"))] + Synth.names.map { ($0, $0) }
                           + Services.systemSounds.map { ($0, L("system · %@", $0.lowercased())) })
                Button(L("play")) { services.playSound(selection) }
                    .teButton(.text)
                    .disabled(selection == "None")
            }
        }
    }
}

private struct BlockingSettings: View {
    let services: Services
    @State private var newSite = ""

    var body: some View {
        let store = services.store
        let allow = store.settings.blockMode == .allowList
        let appsKey: WritableKeyPath<AppSettings, [BlockedApp]> = allow ? \.allowApps : \.blockApps
        let sitesKey: WritableKeyPath<AppSettings, [String]> = allow ? \.allowSites : \.blockSites
        TEPage {
            TESection(title: L("blocking"),
                      note: allow ? L("Only the apps and websites below are allowed while you work. Browsers stay open, but only allowed sites load.")
                                  : L("The apps and websites below are blocked while you work.")) {
                TEToggleRow(label: L("Block distractions during work intervals"),
                            isOn: setting(store, \.blockingEnabled) { services.updateTimerDependents() })
                TERow(label: L("Mode")) {
                    TESegmented(selection: setting(store, \.blockMode),
                                options: BlockMode.allCases.map { ($0, $0.title.lowercased()) })
                        .frame(width: 220)
                }
            }
            TESection(title: allow ? L("apps to allow") : L("apps to block")) {
                ForEach(store.settings[keyPath: appsKey]) { app in
                    TERow(label: app.name, detail: app.bundleID) {
                        Button(L("remove")) { store.settings[keyPath: appsKey].removeAll { $0 == app } }.teButton(.text)
                    }
                }
                Button(L("add apps")) { addApps(to: appsKey) }.teButton().padding(.top, TE.s2)
            }
            TESection(title: allow ? L("websites to allow") : L("websites to block"),
                      note: L("Works in Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera. Subdomains are included. macOS asks once per browser for permission.")) {
                ForEach(store.settings[keyPath: sitesKey], id: \.self) { site in
                    TERow(label: site) {
                        Button(L("remove")) { store.settings[keyPath: sitesKey].removeAll { $0 == site } }.teButton(.text)
                    }
                }
                HStack(spacing: TE.s1) {
                    TextField("", text: $newSite, prompt: Text("example.com").foregroundStyle(TE.inkSecondary))
                        .teField()
                        .onSubmit { addSite(to: sitesKey) }
                    Button(L("add")) { addSite(to: sitesKey) }
                        .teButton()
                        .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, TE.s2)
            }
            Button(L("open automation privacy settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
            .teButton(.text)
        }
    }

    private func addSite(to key: WritableKeyPath<AppSettings, [String]>) {
        var site = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        if let range = site.range(of: "://") { site = String(site[range.upperBound...]) }
        site = String(site.prefix { $0 != "/" })
        if site.hasPrefix("www.") { site.removeFirst(4) }
        guard !site.isEmpty else { return }
        if !services.store.settings[keyPath: key].contains(site) { services.store.settings[keyPath: key].append(site) }
        newSite = ""
    }

    private func addApps(to key: WritableKeyPath<AppSettings, [BlockedApp]>) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.message = L("Choose apps")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if !services.store.settings[keyPath: key].contains(where: { $0.bundleID == id }) {
                services.store.settings[keyPath: key].append(BlockedApp(bundleID: id, name: name))
            }
        }
    }
}

private struct AutomationSettings: View {
    let services: Services

    var body: some View {
        let store = services.store
        TEPage {
            TESection(title: L("run a shortcut when"),
                      note: L("Enter the name of a shortcut from the Shortcuts app. It runs when the event happens, e.g. to turn on a Focus mode when work starts.")) {
                ForEach(AutomationEvent.allCases) { event in
                    TERow(label: event.title) {
                        HStack(spacing: TE.s1) {
                            TextField("", text: Binding(
                                get: { store.settings.shortcuts[event.rawValue] ?? "" },
                                set: { store.settings.shortcuts[event.rawValue] = $0.isEmpty ? nil : $0 }
                            ), prompt: Text(L("shortcut name")).foregroundStyle(TE.inkSecondary))
                            .teField()
                            .frame(width: 200)
                            Button(L("test")) { Automation.run(event, store.settings) }
                                .teButton(.text)
                                .disabled((store.settings.shortcuts[event.rawValue] ?? "").isEmpty)
                        }
                    }
                }
            }
            Button(L("open shortcuts")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                .teButton(.text)
        }
    }
}

private struct SyncSettings: View {
    let services: Services
    @State private var importSession: ImportSession?

    var body: some View {
        let sync = services.sync
        let store = services.store
        TEPage {
            TESection(title: L("folder sync"),
                      note: L("Pick a folder inside iCloud Drive, Dropbox, Google Drive, OneDrive, Nextcloud, Syncthing or a network share, and choose the same folder on your other Macs. Each Mac writes only its own file into “%@”, so the cloud never sees conflicting edits. Settings stay per Mac; tasks, work types and history are synced.", "\(FolderSync.subfolder)")) {
                if let folder = sync.folderURL {
                    TERow(label: L("Folder"), detail: folder.path(percentEncoded: false)) { EmptyView() }
                    TERow(label: L("Status")) {
                        HStack(spacing: 6) {
                            if sync.isSyncing {
                                LED(on: true)
                                Code(L("syncing"))
                            } else if let error = sync.lastError {
                                LED(on: true)
                                Text(error).font(TE.body(12)).foregroundStyle(TE.ink).lineLimit(2)
                            } else if let last = sync.lastSync {
                                Code(sync.peerCount == 1 ? L("synced %@ · 1 other Mac", last.timeText) : L("synced %@ · %@ other Macs", last.timeText, "\(sync.peerCount)"))
                            } else {
                                Code(L("waiting"))
                            }
                        }
                    }
                    HStack(spacing: TE.s1) {
                        Button(L("sync now")) { sync.syncNow() }.teButton(.primary)
                        Button(L("show in finder")) { NSWorkspace.shared.activateFileViewerSelecting([sync.syncDirectory ?? folder]) }.teButton()
                        Button(L("change folder")) { sync.chooseFolder() }.teButton()
                        Spacer()
                        Button(L("disconnect")) { sync.disconnect() }.teButton(.text)
                    }
                    .padding(.top, TE.s2)
                } else {
                    TERow(label: L("Not syncing")) {
                        Button(L("choose sync folder")) { sync.chooseFolder() }.teButton(.primary)
                    }
                }
            }
            TESection(title: L("data")) {
                TERow(label: L("Library")) { Code(L("%@ tasks · %@ intervals", "\(store.tasks.count)", "\(store.intervals.count)")) }
                HStack(spacing: TE.s1) {
                    Button(L("export csv")) { CSVExport.run(store: store) }.teButton()
                    Button(L("show data folder")) { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }.teButton()
                }
                .padding(.top, TE.s2)
            }
            TESection(title: L("import from other apps"),
                      note: L("CSV exports are recognized from Toggl Track, Clockify and plumb; other timer apps' CSVs are matched by column name, and you can adjust the columns before importing. Importing the same file twice adds nothing.")) {
                TERow(label: L("CSV export"), detail: L("Toggl Track, Clockify, Forest, Session, Focus To-Do, …")) {
                    Button(L("choose file")) { importSession = ImportSession.choose() }.teButton()
                }
                TERow(label: L("Be Focused"), detail: L("reads its data file on this Mac")) {
                    Button(L("import")) { BeFocusedImport.runInteractive(store: store) }.teButton()
                }
                TERow(label: L("TomatoBar"), detail: TomatoBarImport.existingFile == nil ? L("choose its TomatoBar.log") : L("found its log on this Mac")) {
                    Button(L("import")) {
                        if let file = TomatoBarImport.existingFile { importSession = ImportSession.read(file) }
                        else { importSession = ImportSession.choose() }
                    }
                    .teButton()
                }
            }
        }
        .sheet(item: $importSession) { session in ImportSheet(store: store, session: session) }
    }
}

private struct IntegrationSettings: View {
    @State private var copied: String?
    @State private var cliMessage: String?

    private var executable: String {
        Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Plumb").path
            : (Bundle.main.executablePath ?? "Plumb")
    }

    private var claudeCommand: String { "claude mcp add --scope user plumb -- \"\(executable)\" --mcp" }

    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "plumb": { "command": "\(executable)", "args": ["--mcp"] }
          }
        }
        """
    }

    private static let cliPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/plumb")

    var body: some View {
        TEPage {
            TESection(title: L("mcp server"),
                      note: L("Lets an AI assistant read your tasks, reports and forecasts and run the timer, e.g. “start 50 minutes on my thesis” or “how far am I this week?”. It runs locally and talks only to this app.")) {
                CopyRow(label: L("Claude Code"), value: claudeCommand, copied: $copied)
                CopyRow(label: L("Claude Desktop, Cursor and other MCP clients"), value: jsonConfig, copied: $copied)
                TERow(label: L("Tools"), detail: MCPServer.tools.map(\.name).joined(separator: " · ")) { EmptyView() }
            }
            TESection(title: L("command line"),
                      note: L("Installs a small script at ~/.local/bin/plumb. Make sure that folder is on your PATH.")) {
                TERow(label: "plumb", detail: "plumb status · plumb start thesis · plumb note \"drafted 3.2\" · plumb report this week") {
                    Button(FileManager.default.fileExists(atPath: Self.cliPath.path) ? L("reinstall") : L("install")) { installCLI() }
                        .teButton()
                }
                if let cliMessage { Code(cliMessage, color: TE.ink).padding(.top, TE.s1) }
            }
            TESection(title: L("links"),
                      note: L("Use these in Shortcuts, Raycast, Alfred, Stream Deck or a browser bookmark.")) {
                ForEach(["plumb://toggle", "plumb://start?task=Thesis", "plumb://extend?minutes=5",
                         "plumb://note?text=drafted%20section%203", "plumb://add?title=Read%20paper&estimate=4",
                         "plumb://open/reports"], id: \.self) { link in
                    CopyRow(label: link, value: link, copied: $copied, compact: true)
                }
            }
        }
    }

    private func installCLI() {
        let script = "#!/bin/sh\n# Installed by Plumb. Talks to the running app.\nexec \"\(executable)\" --cli \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: Self.cliPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: Self.cliPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.cliPath.path)
            cliMessage = L("installed at %@", Self.cliPath.path)
        } catch {
            cliMessage = L("could not install: %@", error.localizedDescription)
        }
    }
}

/// A value to copy, in monospaced text, with a copy button.
private struct CopyRow: View {
    let label: String
    let value: String
    @Binding var copied: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if compact {
                    Text(value).font(.system(size: 12, weight: .light, design: .monospaced)).foregroundStyle(TE.ink)
                        .textSelection(.enabled)
                } else {
                    Text(label).font(TE.body()).foregroundStyle(TE.ink)
                }
                Spacer()
                Button(copied == value ? L("copied") : L("copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = value
                }
                .teButton(.text)
            }
            if !compact {
                Text(value)
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .foregroundStyle(TE.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TE.surface)
                    .overlay(Rectangle().strokeBorder(TE.hairline, lineWidth: 1))
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// Background sound while working: generated noise or an internet radio station.
private struct AmbientSection: View {
    let services: Services
    @State private var customURL = ""

    var body: some View {
        let store = services.store
        let source = AmbientSource.find(store.settings.ambientSource)
        let apply = { services.updateTimerDependents() }
        TESection(title: L("background sound"),
                  note: L("Plays while a work interval runs and pauses with the timer. Noise and binaural beats are generated on this Mac, so there is nothing to license. Binaural beats need headphones: each ear gets a slightly different tone and the brain hears the difference as a slow pulse. How much they help varies from person to person.")) {
            TERow(label: L("Sound"), detail: source.detail.isEmpty ? nil : source.detail) {
                TEMenu(selection: setting(store, \.ambientSource, then: apply),
                       options: AmbientSource.catalog.map { ($0.id, $0.name) }, minWidth: 200)
            }
            if source.kind == .custom {
                TERow(label: L("Stream URL")) {
                    TextField("", text: $customURL, prompt: Text("https://…").foregroundStyle(TE.inkSecondary))
                        .teField()
                        .frame(width: 280)
                        .onSubmit {
                            store.settings.ambientCustomURL = customURL
                            apply()
                        }
                }
            }
            TERow(label: L("Volume")) { TESlider(value: setting(store, \.ambientVolume, then: apply)) }
            TEToggleRow(label: L("Also during breaks"), isOn: setting(store, \.ambientDuringBreaks, then: apply))
            TERow(label: L("Status")) { AmbientStatus(player: services.ambient) }
        }
        .onAppear { customURL = store.settings.ambientCustomURL ?? "" }
    }
}

/// "playing · Artist – Title", "connecting", or the error.
struct AmbientStatus: View {
    let player: AmbientPlayer

    var body: some View {
        HStack(spacing: 6) {
            switch player.state {
            case .stopped:
                Code(L("plays when work starts"))
            case .loading:
                LED(on: false)
                Code(L("connecting"))
            case .playing:
                LED(on: true)
                Code(player.nowPlaying.map { L("playing · %@", $0) } ?? L("playing"), color: TE.ink)
            case .failed(let message):
                LED(on: true)
                Text(message).font(TE.body(12)).foregroundStyle(TE.ink)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
