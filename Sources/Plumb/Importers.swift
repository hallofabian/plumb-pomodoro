import CryptoKit
import Foundation

/// One interval read from another app's export, before it becomes a FocusInterval.
struct ImportedRecord: Equatable {
    var start: Date
    var duration: TimeInterval
    var phase: Phase = .work
    var outcome: Outcome = .completed
    var task: String?
    var note: String?
    /// Stable identity of the source row, so importing a file twice adds nothing.
    var key: String
}

enum ImportFormat: String {
    case plumb = "plumb CSV"
    case toggl = "Toggl Track"
    case clockify = "Clockify"
    case genericCSV = "CSV"
    case tomatoBar = "TomatoBar log"
}

// MARK: - CSV

/// CSV import with format detection (Toggl Track, Clockify, plumb's own export)
/// and a column mapping for anything else.
struct CSVImport {
    struct Mapping: Equatable {
        var startDate: Int?
        var startTime: Int?
        var endDate: Int?
        var endTime: Int?
        var duration: Int?
        var durationUnit = DurationUnit.clock
        var task: Int?
        var note: Int?
        var phase: Int?
        var outcome: Int?

        var isUsable: Bool { startDate != nil && (duration != nil || endDate != nil || endTime != nil) }
    }

    enum DurationUnit: String, CaseIterable {
        /// "1:25:00", "25:00" (h:mm), "01:25"
        case clock
        case minutes
        case hours
        case seconds

        var title: String {
            switch self {
            case .clock: "h:mm:ss"
            case .minutes: "minutes"
            case .hours: "hours (decimal)"
            case .seconds: "seconds"
            }
        }
    }

    let headers: [String]
    let rows: [[String]]
    var format: ImportFormat
    var mapping: Mapping
    /// Whether 03/04/2026 means 3 April (true) or 4 March.
    var dayFirst: Bool
    /// True when the file does not settle day/month order on its own.
    let dayOrderAmbiguous: Bool

    init?(text: String) {
        let table = Self.parse(text)
        guard let header = table.first, header.count >= 2 else { return nil }
        headers = header.map { $0.trimmingCharacters(in: .whitespaces) }
        rows = table.dropFirst().filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        (format, mapping) = Self.detect(headers)
        let order = Self.dayOrder(rows: rows, columns: [mapping.startDate, mapping.endDate].compactMap { $0 })
        dayFirst = order ?? (Locale.current.identifier.hasPrefix("en_US") ? false : true)
        dayOrderAmbiguous = order == nil
    }

    // MARK: Detection

    static func detect(_ headers: [String]) -> (ImportFormat, Mapping) {
        let lower = headers.map { $0.lowercased() }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { lower.firstIndex(of: $0) }.first }
        func colContaining(_ parts: String...) -> Int? {
            lower.firstIndex { header in parts.contains { header.contains($0) } }
        }

        if Set(["date", "start", "end", "task", "phase", "outcome", "minutes"]).isSubset(of: lower) {
            return (.plumb, Mapping(startDate: col("date"), startTime: col("start"), endDate: col("date"), endTime: col("end"),
                                    duration: col("minutes"), durationUnit: .minutes, task: col("task"), note: col("note"),
                                    phase: col("phase"), outcome: col("outcome")))
        }
        if lower.contains("duration (decimal)") || lower.contains("duration (h)") {
            return (.clockify, Mapping(startDate: col("start date"), startTime: col("start time"),
                                       endDate: col("end date"), endTime: col("end time"),
                                       duration: col("duration (h)") ?? col("duration (decimal)"),
                                       durationUnit: lower.contains("duration (h)") ? .clock : .hours,
                                       task: col("project") ?? col("description"),
                                       note: col("project") != nil ? col("description") : nil))
        }
        if lower.contains("start date"), lower.contains("start time"), lower.contains("duration") {
            return (.toggl, Mapping(startDate: col("start date"), startTime: col("start time"),
                                    endDate: col("end date"), endTime: col("end time"),
                                    duration: col("duration"), durationUnit: .clock,
                                    task: col("project") ?? col("description"),
                                    note: col("project") != nil ? col("description") : nil))
        }
        // Anything else: guess from common column names.
        var m = Mapping()
        m.startDate = col("start date", "start", "started", "start time", "begin", "date", "day", "from", "started at", "start_time")
            ?? colContaining("start", "date")
        let startDateHeader = m.startDate.map { lower[$0] } ?? ""
        if !startDateHeader.contains("time") {
            m.startTime = col("start time", "time", "start_time").flatMap { $0 == m.startDate ? nil : $0 }
        }
        m.endDate = col("end date", "end", "ended", "end time", "finish", "stop", "to", "ended at", "end_time")
        m.endTime = col("end time", "end_time").flatMap { $0 == m.endDate ? nil : $0 }
        if let d = col("minutes", "mins", "duration (min)", "duration (minutes)") {
            m.duration = d; m.durationUnit = .minutes
        } else if let d = col("hours", "duration (hours)") {
            m.duration = d; m.durationUnit = .hours
        } else if let d = col("seconds", "duration (s)") {
            m.duration = d; m.durationUnit = .seconds
        } else {
            m.duration = col("duration", "length", "time spent", "elapsed")
        }
        m.task = col("task", "project", "title", "name", "activity", "category", "tag", "tags", "label")
        m.note = col("note", "notes", "description", "comment", "comments", "memo")
        if m.note == m.task { m.note = nil }
        return (.genericCSV, m)
    }

    /// Day-first if any date's first number is over 12, month-first if any second is; nil if undecided.
    /// ISO dates (2026-10-18) never decide anything.
    static func dayOrder(rows: [[String]], columns: [Int]) -> Bool? {
        for row in rows {
            for c in columns where c < row.count {
                let text = row[c].trimmingCharacters(in: .whitespaces)
                guard !text.prefix(4).allSatisfy(\.isNumber) else { continue }
                let parts = text.split(whereSeparator: { "/.- ".contains($0) }).prefix(2).compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                if parts[0] > 12 { return true }
                if parts[1] > 12 { return false }
            }
        }
        return nil
    }

    // MARK: Records

    func records(source: String) -> (records: [ImportedRecord], failed: Int) {
        guard mapping.isUsable else { return ([], rows.count) }
        var result: [ImportedRecord] = []
        var failed = 0
        for (index, row) in rows.enumerated() {
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let start = Self.date(cell(mapping.startDate), time: cell(mapping.startTime), dayFirst: dayFirst) else {
                failed += 1
                continue
            }
            var duration: TimeInterval?
            if let text = cell(mapping.duration) { duration = Self.duration(text, unit: mapping.durationUnit) }
            if duration == nil, mapping.endDate != nil || mapping.endTime != nil {
                let endDay = cell(mapping.endDate) ?? cell(mapping.startDate)
                if var end = Self.date(endDay, time: cell(mapping.endTime), dayFirst: dayFirst) {
                    if end < start { end = end.addingTimeInterval(86400) } // crossed midnight
                    duration = end.timeIntervalSince(start)
                }
            }
            guard let length = duration, length >= 30, length < 24 * 3600 else {
                failed += 1
                continue
            }
            var record = ImportedRecord(start: start, duration: length.rounded(), task: cell(mapping.task), note: cell(mapping.note),
                                        key: "\(source)|\(index)|\(row.joined(separator: "\u{1F}"))")
            if let phase = cell(mapping.phase).flatMap(Phase.init(rawValue:)) { record.phase = phase }
            if let outcome = cell(mapping.outcome).flatMap(Outcome.init(rawValue:)) { record.outcome = outcome }
            if record.task?.lowercased() == "other" { record.task = nil }
            result.append(record)
        }
        return (result, failed)
    }

    static func date(_ day: String?, time: String?, dayFirst: Bool) -> Date? {
        guard let day else { return nil }
        let text = time.map { "\(day) \($0)" } ?? day
        if let d = CommandCenter.iso.date(from: day) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let dates = ["yyyy-MM-dd", dayFirst ? "dd/MM/yyyy" : "MM/dd/yyyy", "dd.MM.yyyy", dayFirst ? "d/M/yyyy" : "M/d/yyyy",
                     dayFirst ? "dd/MM/yy" : "MM/dd/yy", "d.M.yyyy"]
        let times = ["'T'HH:mm:ss", "'T'HH:mm", " HH:mm:ss", " HH:mm", " h:mm:ss a", " h:mm a", " H:mm", ""]
        for d in dates {
            for t in times {
                f.dateFormat = d + t
                if let parsed = f.date(from: text) { return parsed }
            }
        }
        return nil
    }

    static func duration(_ text: String, unit: DurationUnit) -> TimeInterval? {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Double($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let n = parts.map { $0! }
            return n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : (n.count == 2 ? n[0] * 3600 + n[1] * 60 : nil)
        }
        guard let value = Double(t) else { return nil }
        switch unit {
        case .clock, .minutes: return value * 60
        case .hours: return value * 3600
        case .seconds: return value
        }
    }

    /// RFC 4180 CSV with automatic delimiter (comma, semicolon or tab).
    static func parse(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" }
        let delimiter: Character = [";", "\t", ","].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else if c != "\r", c != "\u{FEFF}" {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - TomatoBar

/// Rebuilds intervals from TomatoBar's log: one JSON object per line with
/// {"type": "transition", "event", "fromState", "toState", "timestamp"}.
/// States are idle/work/rest; "timerFired" ends an interval normally.
enum TomatoBarImport {
    static var candidateFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/com.github.ivoronin.TomatoBar/Data/Library/Caches/TomatoBar.log"),
            home.appendingPathComponent("Library/Caches/TomatoBar.log"),
        ]
    }

    static var existingFile: URL? { candidateFiles.first { FileManager.default.isReadableFile(atPath: $0.path) } }

    static func records(from text: String) -> [ImportedRecord] {
        struct Event: Decodable {
            var type: String
            var timestamp: Double
            var event: String?
            var fromState: String?
            var toState: String?
        }
        let events = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [ImportedRecord] = []
        var open: (state: String, start: Double)?
        for e in events {
            if e.type == "appstart" { open = nil; continue }
            guard e.type == "transition" else { continue }
            if let current = open, e.fromState == current.state {
                let length = e.timestamp - current.start
                if length >= 30 {
                    let isWork = current.state == "work"
                    result.append(ImportedRecord(
                        start: Date(timeIntervalSince1970: current.start), duration: length.rounded(),
                        phase: isWork ? .work : (length >= 15 * 60 ? .longBreak : .shortBreak),
                        outcome: e.event == "timerFired" ? .completed : .skipped,
                        key: "tomatobar|\(current.start)|\(current.state)"))
                }
                open = nil
            }
            if let to = e.toState, to == "work" || to == "rest" { open = (to, e.timestamp) }
        }
        return result
    }
}

// MARK: - Applying

@MainActor
enum ImportApplier {
    struct Summary { var intervals = 0; var newTasks = 0 }

    /// Adds records to the library. Tasks are matched by title or created; ids are
    /// derived from the source rows, so a second import of the same file adds nothing.
    @discardableResult
    static func apply(_ records: [ImportedRecord], to store: Store, defaultTask: UUID? = nil) -> Summary {
        let stamp = Date(timeIntervalSince1970: 0)
        var byTitle: [String: UUID] = [:]
        for t in store.activeTasks + store.completedTasks { byTitle[t.title.lowercased()] = byTitle[t.title.lowercased()] ?? t.id }
        var library = Library()
        var summary = Summary()
        for r in records {
            var taskID = defaultTask
            if let title = r.task?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                if let existing = byTitle[title.lowercased()] {
                    taskID = existing
                } else {
                    let id = stableID("task|" + title.lowercased())
                    byTitle[title.lowercased()] = id
                    library.tasks.append(FocusTask(id: id, title: title, createdAt: r.start, updatedAt: stamp))
                    summary.newTasks += 1
                }
            }
            library.intervals.append(FocusInterval(id: stableID(r.key), taskID: taskID, phase: r.phase, start: r.start,
                                                   duration: r.duration, outcome: r.outcome, note: r.note, updatedAt: stamp))
        }
        let before = store.library.intervals.count
        store.merge(library, isLocalChange: true)
        summary.intervals = store.library.intervals.count - before
        return summary
    }

    static func stableID(_ key: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(key.utf8)))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
