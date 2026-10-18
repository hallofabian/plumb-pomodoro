import AppKit
import Observation

/// Syncs the library through any folder the user picks (iCloud Drive, Dropbox,
/// Google Drive, Nextcloud, Syncthing, a NAS share, ...).
///
/// Every Mac writes only its own file, `<folder>/Plumb Sync/<device-id>.json`, and
/// reads everyone else's. Because no file ever has two writers, cloud clients never
/// create conflicted copies; records merge last-writer-wins with tombstones.
@MainActor
@Observable
final class FolderSync {
    private(set) var folderURL: URL?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var peerCount = 0

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var lastWritten: Data?
    @ObservationIgnored private var resyncRequested = false

    static let subfolder = "Plumb Sync"

    init(store: Store) {
        self.store = store
    }

    var syncDirectory: URL? { folderURL?.appendingPathComponent(Self.subfolder, isDirectory: true) }

    func start() {
        folderURL = resolveFolder()
        guard let base = folderURL else { return }
        // The sync subfolder was renamed with the app; carry it over once.
        let legacy = base.appendingPathComponent("Fok" + "us Sync", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path), let current = syncDirectory, !fm.fileExists(atPath: current.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        startWatching()
        syncNow()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Sync"
        panel.message = "Choose a folder that your cloud service syncs. Plumb stores its data in a \"\(Self.subfolder)\" subfolder."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.syncFolderBookmark = try? url.bookmarkData()
        store.settings.syncFolderPath = url.path
        lastWritten = nil
        lastError = nil
        start()
    }

    func disconnect() {
        stopWatching()
        store.settings.syncFolderBookmark = nil
        store.settings.syncFolderPath = nil
        folderURL = nil
        lastSync = nil
        lastError = nil
        peerCount = 0
    }

    /// Debounced sync after local edits.
    func scheduleSync(after delay: TimeInterval = 2) {
        guard folderURL != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func syncNow() {
        guard let dir = syncDirectory else { return }
        guard !isSyncing else { resyncRequested = true; return }
        isSyncing = true
        let deviceID = store.settings.deviceID
        let ownFile = dir.appendingPathComponent("\(deviceID.uuidString).json")

        Task.detached(priority: .utility) {
            let result = Result { try Self.readPeers(in: dir, excluding: ownFile) }
            await MainActor.run { self.finishRead(result, ownFile: ownFile, deviceID: deviceID) }
        }
    }

    // MARK: Internals

    private func finishRead(_ result: Result<[SyncFile], Error>, ownFile: URL, deviceID: UUID) {
        switch result {
        case .failure(let error):
            finish(error: error)
        case .success(let peers):
            peerCount = peers.count
            for peer in peers where peer.format <= SyncFile.currentFormat {
                store.merge(peer.library)
            }
            let file = SyncFile(deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac", library: store.library.normalized)
            guard let data = try? Self.encoder.encode(file.libraryOnly), data != lastWritten else {
                finish(error: nil)
                return
            }
            Task.detached(priority: .utility) {
                let written = Result { try Self.write(file, to: ownFile) }
                await MainActor.run {
                    if case .success = written { self.lastWritten = data }
                    if case .failure(let error) = written { self.finish(error: error) } else { self.finish(error: nil) }
                }
            }
        }
    }

    private func finish(error: Error?) {
        isSyncing = false
        if let error {
            lastError = error.localizedDescription
        } else {
            lastError = nil
            lastSync = Date()
        }
        if resyncRequested {
            resyncRequested = false
            scheduleSync(after: 0.5)
        }
    }

    private func resolveFolder() -> URL? {
        if let bookmark = store.settings.syncFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                if stale { store.settings.syncFolderBookmark = try? url.bookmarkData() }
                store.settings.syncFolderPath = url.path
                return url
            }
        }
        return store.settings.syncFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func startWatching() {
        stopWatching()
        // Poll as a fallback: some cloud clients update files without a directory event.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        guard let dir = syncDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSync(after: 1) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        watcher?.cancel()
        watcher = nil
        pending?.cancel()
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated private static func readPeers(in dir: URL, excluding ownFile: URL) throws -> [SyncFile] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != ownFile.lastPathComponent && !$0.lastPathComponent.hasPrefix(".") }
        return files.compactMap { url in
            var data: Data?
            var coordError: NSError?
            // Coordinated reads make iCloud Drive download evicted files first.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { data = try? Data(contentsOf: $0) }
            return data.flatMap { try? JSONDecoder().decode(SyncFile.self, from: $0) }
        }
    }

    nonisolated private static func write(_ file: SyncFile, to url: URL) throws {
        let data = try encoder.encode(file)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
    }
}

struct SyncFile: Codable {
    static let currentFormat = 1

    var format = SyncFile.currentFormat
    var deviceID: UUID
    var deviceName: String
    var writtenAt = Date()
    var library: Library

    /// The file without its timestamp, used to skip writes when nothing changed.
    var libraryOnly: SyncFile {
        var copy = self
        copy.writtenAt = .distantPast
        return copy
    }
}
