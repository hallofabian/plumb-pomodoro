import SwiftUI
import UniformTypeIdentifiers

/// A file chosen for import, ready for preview.
struct ImportSession: Identifiable {
    enum Source {
        case csv(CSVImport)
        case tomatoBar([ImportedRecord])
    }

    let id = UUID()
    let fileName: String
    var source: Source

    var format: ImportFormat {
        switch source {
        case .csv(let file): file.format
        case .tomatoBar: .tomatoBar
        }
    }

    func records() -> (records: [ImportedRecord], failed: Int) {
        switch source {
        case .csv(let file): file.records(source: fileName)
        case .tomatoBar(let records): (records, 0)
        }
    }

    /// Asks for a CSV or log file and reads it. Nil if cancelled or unreadable.
    @MainActor
    static func choose(start: URL? = nil) -> ImportSession? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .log, .json]
        panel.message = L("Choose a CSV export (Toggl Track, Clockify, plumb, or any timer app) or a TomatoBar log")
        if let start { panel.directoryURL = start }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return read(url)
    }

    @MainActor
    static func read(_ url: URL) -> ImportSession? {
        guard let data = try? Data(contentsOf: url) else {
            alert(L("Could not read %@.", url.lastPathComponent))
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\"fromState\"") {
            return ImportSession(fileName: url.lastPathComponent, source: .tomatoBar(TomatoBarImport.records(from: text)))
        }
        guard let csv = CSVImport(text: text) else {
            alert(L("%@ doesn't look like a CSV file with a header row.", url.lastPathComponent))
            return nil
        }
        return ImportSession(fileName: url.lastPathComponent, source: .csv(csv))
    }

    @MainActor
    private static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("Import not possible")
        alert.informativeText = message
        alert.runModal()
    }
}

/// Preview and column mapping before anything is written.
struct ImportSheet: View {
    let store: Store
    @State var session: ImportSession
    @State private var defaultTask: UUID?
    @State private var result: ImportApplier.Summary?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let (records, failed) = session.records()
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: TE.s3) {
                    VStack(alignment: .leading, spacing: TE.s1) {
                        Code(L("import · %@", "\(session.format.rawValue)"))
                        Text(session.fileName).font(TE.heading()).foregroundStyle(TE.ink).lineLimit(1)
                    }
                    preview(records)
                    TESection(title: L("tasks"),
                              note: L("Rows with a task or project name go to the task of that name; missing tasks are created.")) {
                        TERow(label: L("Rows without a task go to")) {
                            TEMenu(selection: $defaultTask,
                                   options: [(nil, L("other"))] + store.activeTasks.map { (Optional($0.id), $0.title) })
                        }
                    }
                    if case .csv(let file) = session.source { mapping(file) }
                }
                .padding(TE.s3)
            }
            Rule(strong: true)
            HStack(spacing: TE.s1) {
                if let result {
                    Code(result.intervals == 0 ? L("nothing new: these intervals are already in plumb")
                                               : L("imported %@ intervals · %@ new tasks", "\(result.intervals)", "\(result.newTasks)"), color: TE.ink)
                } else {
                    Code(L("%@ intervals ready", "\(records.count)") + (failed > 0 ? L(" · %@ rows skipped", "\(failed)") : ""), color: TE.ink)
                }
                Spacer()
                if result == nil {
                    Button(L("cancel")) { dismiss() }.teButton().keyboardShortcut(.cancelAction)
                    Button(L("import %@", "\(records.count)")) {
                        result = ImportApplier.apply(records, to: store, defaultTask: defaultTask)
                    }
                    .teButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(records.isEmpty)
                } else {
                    Button(L("done")) { dismiss() }.teButton(.primary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(TE.s2)
        }
        .frame(width: 640, height: 640)
        .background(TE.canvas)
    }

    @ViewBuilder
    private func mapping(_ file: CSVImport) -> some View {
        let columns: [(Int?, String)] = [(nil, "—")] + file.headers.enumerated().map { (Optional($0.offset), $0.element) }
        TESection(title: L("columns"),
                  note: file.format == .genericCSV
                      ? L("Matched by column name. Check the preview below and adjust if something is off.")
                      : L("Recognized as a %@ export.", file.format.rawValue)) {
            columnRow(L("Start date (or date and time)"), \.startDate, columns)
            columnRow(L("Start time"), \.startTime, columns)
            columnRow(L("End date"), \.endDate, columns)
            columnRow(L("End time"), \.endTime, columns)
            TERow(label: L("Duration")) {
                HStack(spacing: TE.s1) {
                    TEMenu(selection: csvBinding(\.mapping.durationUnit),
                           options: CSVImport.DurationUnit.allCases.map { ($0, $0.title) }, minWidth: 120)
                    TEMenu(selection: csvBinding(\.mapping.duration), options: columns, minWidth: 160)
                }
            }
            columnRow(L("Task"), \.task, columns)
            columnRow(L("Note"), \.note, columns)
            if file.dayOrderAmbiguous {
                TERow(label: L("Dates are written as"), detail: L("The file doesn't settle this on its own.")) {
                    TESegmented(selection: csvBinding(\.dayFirst), options: [(true, L("day/month")), (false, L("month/day"))])
                        .frame(width: 220)
                }
            }
        }
    }

    private func columnRow(_ label: String, _ keyPath: WritableKeyPath<CSVImport.Mapping, Int?>, _ columns: [(Int?, String)]) -> some View {
        TERow(label: label) {
            TEMenu(selection: csvBinding((\CSVImport.mapping).appending(path: keyPath)), options: columns, minWidth: 160)
        }
    }

    private func csvBinding<T>(_ keyPath: WritableKeyPath<CSVImport, T>) -> Binding<T> {
        Binding(get: {
            guard case .csv(let file) = session.source else { fatalError("CSV mapping without CSV") }
            return file[keyPath: keyPath]
        }, set: { value in
            guard case .csv(var file) = session.source else { return }
            file[keyPath: keyPath] = value
            session.source = .csv(file)
        })
    }

    private func preview(_ records: [ImportedRecord]) -> some View {
        TESection(title: L("preview")) {
            if records.isEmpty {
                Text(L("No intervals could be read. Pick the columns for start and duration (or end) above."))
                    .font(TE.body()).foregroundStyle(TE.inkSecondary).padding(.vertical, 10)
            }
            ForEach(Array(records.prefix(8).enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: TE.s2) {
                    Text(r.start.dateTimeText)
                        .font(TE.body(12).monospacedDigit()).frame(width: 130, alignment: .leading)
                    Text(formatDuration(r.duration)).font(TE.body(12).monospacedDigit()).frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.task ?? (defaultTask.flatMap { store.task($0)?.title } ?? L("other"))).font(TE.body(12))
                        if let note = r.note { Text(note).font(TE.body(11)).foregroundStyle(TE.inkSecondary).lineLimit(1) }
                    }
                    Spacer()
                    if r.phase != .work { Code(r.phase.label) }
                    if r.outcome == .skipped { Code(L("skipped")) }
                }
                .foregroundStyle(TE.ink)
                .padding(.vertical, 6)
                Rule()
            }
            if records.count > 8 { Code(L("and %@ more", "\(records.count - 8)")).padding(.top, TE.s1) }
        }
    }
}
