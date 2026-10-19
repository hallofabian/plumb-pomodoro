import Charts
import SwiftUI

enum ReportPeriod: String, CaseIterable, Identifiable {
    case today = "today", yesterday = "yesterday", thisWeek = "this week", lastWeek = "last week"
    case thisMonth = "this month", lastMonth = "last month", thisYear = "this year", all = "all time", custom = "custom"

    var id: String { rawValue }

    /// Shown in the interface; the raw value stays English for the CLI and MCP.
    var title: String { L(rawValue) }

    func range(customStart: Date, customEnd: Date, earliest: Date) -> ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date()
        func interval(_ c: Calendar.Component, _ offset: Int) -> ClosedRange<Date> {
            let base = cal.date(byAdding: c, value: offset, to: now)!
            let i = cal.dateInterval(of: c, for: base)!
            return i.start...i.end.addingTimeInterval(-1)
        }
        switch self {
        case .today: return interval(.day, 0)
        case .yesterday: return interval(.day, -1)
        case .thisWeek: return interval(.weekOfYear, 0)
        case .lastWeek: return interval(.weekOfYear, -1)
        case .thisMonth: return interval(.month, 0)
        case .lastMonth: return interval(.month, -1)
        case .thisYear: return interval(.year, 0)
        case .all: return cal.startOfDay(for: min(earliest, now))...interval(.day, 0).upperBound
        case .custom:
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let end = cal.dateInterval(of: .day, for: max(customStart, customEnd))!.end.addingTimeInterval(-1)
            return start...end
        }
    }
}

struct ReportsView: View {
    let store: Store
    @State private var period: ReportPeriod
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var customEnd = Date()
    @State private var inHours = true
    @State private var selectedBucket: Date?

    init(store: Store, period: ReportPeriod = .thisWeek) {
        self.store = store
        _period = State(initialValue: period)
    }

    var body: some View {
        let report = Report(store: store, range: range, inHours: inHours)
        TEPage {
            filters
            figures(report)
            if report.work.isEmpty {
                VStack(alignment: .leading, spacing: TE.s1) {
                    Code(L("no data"))
                    Text(L("There are no completed intervals for the selected period."))
                        .font(TE.body()).foregroundStyle(TE.inkSecondary)
                }
            } else {
                TESection(title: inHours ? L("hours per %@", "\(report.bucket.name)") : L("intervals per %@", "\(report.bucket.name)"),
                          note: L("Hover a bar for the breakdown by task.")) {
                    timeline(report).frame(height: 240).padding(.top, TE.s2)
                }
                TESection(title: L("by task")) { byTask(report) }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var range: ClosedRange<Date> {
        let earliest = store.intervals.map(\.start).min() ?? Date()
        return period.range(customStart: customStart, customEnd: customEnd, earliest: earliest)
    }

    private var filters: some View {
        HStack(spacing: TE.s1) {
            TEMenu(selection: $period, options: ReportPeriod.allCases.map { ($0, $0.title) })
            if period == .custom {
                DatePicker("from", selection: $customStart, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                Code(L("to"))
                DatePicker("to", selection: $customEnd, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
            }
            Spacer()
            TESegmented(selection: $inHours, options: [(true, L("hours")), (false, L("intervals"))]).frame(width: 180)
        }
    }

    private func figures(_ r: Report) -> some View {
        VStack(spacing: 0) {
            Rule(strong: true)
            HStack(alignment: .top, spacing: 0) {
                cell(Figure(label: L("work time"), value: formatDuration(r.totalSeconds), size: 34))
                Rule(vertical: true)
                cell(Figure(label: L("intervals"), value: "\(r.completedCount)", size: 34))
                Rule(vertical: true)
                cell(Figure(label: L("skipped"), value: "\(r.skippedCount)", size: 34))
                Rule(vertical: true)
                cell(Figure(label: L("tasks done"), value: "\(r.completedTasks)", size: 34))
                Rule(vertical: true)
                cell(Figure(label: L("streak"), value: L("%@d", "\(store.streak())"), size: 34))
                    .help(L("Days in a row at your daily goal; rest days (goal 0) don't break it."))
                Rule(vertical: true)
                cell(Figure(label: L("estimates"), value: Forecast.calibration(store: store).map { numberText($0.median) + "×" } ?? "–", size: 34))
                    .help(L("Work time ÷ estimate, median over all completed tasks with an estimate. Needs 3 such tasks."))
            }
            .fixedSize(horizontal: false, vertical: true)
            Rule()
        }
    }

    private func cell<V: View>(_ content: V) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, TE.s2).padding(.horizontal, 12)
    }

    private func timeline(_ r: Report) -> some View {
        let selectedStart = selectedBucket.flatMap(r.bucketStart)
        return Chart {
            ForEach(r.buckets, id: \.date) { b in
                BarMark(x: .value(L("Date"), b.date, unit: r.bucket.component), y: .value(inHours ? L("Hours") : L("Intervals"), b.value))
                    .foregroundStyle(b.date == selectedStart ? TE.signal : TE.ink)
                    .accessibilityLabel(b.date.text(r.bucket.labelFormat))
                    .accessibilityValue(inHours ? L("%@ h", numberText(b.value)) : "\(Int(b.value))")
            }
            if let selectedStart, let bucket = r.buckets.first(where: { $0.date == selectedStart }) {
                RuleMark(x: .value(L("Date"), selectedStart, unit: r.bucket.component))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: selectedStart.text(r.bucket.labelFormat), total: bucket.value,
                                rows: r.breakdown(at: selectedStart), inHours: inHours)
                    }
            }
        }
        .chartXSelection(value: $selectedBucket)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(TE.hairline)
                AxisValueLabel().font(TE.code).foregroundStyle(TE.inkSecondary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisTick(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(TE.ink)
                AxisValueLabel().font(TE.code).foregroundStyle(TE.inkSecondary)
            }
        }
        .chartPlotStyle { $0.overlay(alignment: .bottom) { Rule(strong: true) } }
    }

    private func byTask(_ r: Report) -> some View {
        let maxValue = r.perTask.map(\.value).max() ?? 1
        return VStack(spacing: 0) {
            ForEach(r.perTask, id: \.name) { row in
                HStack(spacing: TE.s2) {
                    Text(row.name).font(TE.body()).foregroundStyle(TE.ink).lineLimit(1)
                        .frame(width: 200, alignment: .leading)
                    GeometryReader { geo in
                        Rectangle().fill(TE.ink)
                            .frame(width: max(1, geo.size.width * row.value / maxValue), height: 3)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 12)
                    Text(inHours ? L("%@ h", numberText(row.value)) : "\(Int(row.value))")
                        .font(TE.body(12).monospacedDigit()).foregroundStyle(TE.inkSecondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                Rule()
            }
        }
    }
}

private struct Tooltip: View {
    let title: String
    let total: Double
    let rows: [(String, Double)]
    let inHours: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Code(title, color: TE.ink)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(format(row.1)).monospacedDigit()
                }
                .font(TE.body(11))
                .foregroundStyle(TE.ink)
            }
            if rows.count > 1 {
                Rule()
                HStack { Text(L("total")); Spacer(); Text(format(total)).monospacedDigit() }
                    .font(TE.body(11)).foregroundStyle(TE.ink)
            }
        }
        .padding(10)
        .frame(width: 210)
        .background(TE.canvas)
        .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
    }

    private func format(_ v: Double) -> String { inHours ? L("%@ h", numberText(v)) : "\(Int(v))" }
}

/// Aggregates intervals for the reports window.
private struct Report {
    enum Granularity {
        case day, week, month

        var component: Calendar.Component { self == .day ? .day : (self == .week ? .weekOfYear : .month) }
        var name: String { self == .day ? L("day") : (self == .week ? L("week") : L("month")) }
        var labelFormat: Date.FormatStyle {
            switch self {
            case .day: .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            case .week: .dateTime.day().month(.abbreviated).year()
            case .month: .dateTime.month(.wide).year()
            }
        }
    }

    let work: [FocusInterval]
    let completedCount: Int
    let skippedCount: Int
    let totalSeconds: TimeInterval
    let completedTasks: Int
    let bucket: Granularity
    let buckets: [(date: Date, value: Double)]
    let perTask: [(name: String, value: Double)]
    private let byBucketAndTask: [Date: [String: Double]]

    @MainActor
    init(store: Store, range: ClosedRange<Date>, inHours: Bool) {
        let cal = Calendar.current
        work = store.intervals.filter { $0.phase == .work && range.contains($0.start) }
        let completed = work.filter { $0.outcome == .completed }
        completedCount = completed.count
        skippedCount = work.count - completed.count
        // Skipped intervals were still worked, so they count toward time.
        totalSeconds = work.reduce(0) { $0 + $1.duration }

        let finished = store.completedTasks.filter { range.contains($0.completedAt ?? .distantPast) }
        completedTasks = finished.count

        let days = range.upperBound.timeIntervalSince(range.lowerBound) / 86400
        let granularity: Granularity = days > 400 ? .month : (days > 70 ? .week : .day)
        bucket = granularity

        var grouped: [Date: [String: Double]] = [:]
        var perTaskTotals: [String: Double] = [:]
        for i in completed {
            let value = inHours ? i.duration / 3600 : 1
            let start = cal.dateInterval(of: granularity.component, for: i.start)!.start
            let title = store.title(for: i.taskID)
            grouped[start, default: [:]][title, default: 0] += value
            perTaskTotals[title, default: 0] += value
        }
        byBucketAndTask = grouped
        buckets = grouped.map { (date: $0.key, value: $0.value.values.reduce(0, +)) }.sorted { $0.date < $1.date }
        perTask = perTaskTotals.map { (name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
    }

    func bucketStart(_ date: Date) -> Date? {
        Calendar.current.dateInterval(of: bucket.component, for: date)?.start
    }

    /// Up to four tasks for one bar; the rest are summed.
    func breakdown(at start: Date) -> [(String, Double)] {
        let rows = (byBucketAndTask[start] ?? [:]).sorted { $0.value > $1.value }
        var result = rows.prefix(4).map { ($0.key, $0.value) }
        if rows.count > 4 { result.append((L("%@ more", "\(rows.count - 4)"), rows.dropFirst(4).reduce(0) { $0 + $1.value })) }
        return result
    }
}
