import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum StatisticsRange: TimeInterval, CaseIterable, Identifiable {
    case oneHour = 3600
    case sixHours = 21_600
    case day = 86_400
    case week = 604_800

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .oneHour: return "1 h"
        case .sixHours: return "6 h"
        case .day: return "24 h"
        case .week: return "7 d"
        }
    }
}

/// Charts over the recorded history: battery level, power, temperature and the estimated
/// time until the threshold. AC periods are shaded, events are vertical rules, and hovering
/// any chart scrubs all four with a readout of the nearest sample.
struct StatisticsView: View {
    let viewModel: MenuBarViewModel

    @State private var range = StatisticsRange.sixHours
    @State private var exportError: String?
    @State private var hoverDate: Date?
    @State private var series = PreparedSeries()
    /// SwiftUI keeps a closed window and its charts alive and redrawing; nothing is built
    /// while the window is off screen, so its memory is released.
    @State private var visible = false

    /// Downsampled rows and derived spans for the selected range, rebuilt only when the
    /// range or the history changes, not on every mouse move.
    private struct PreparedSeries {
        var entries: [HistoryEntry] = []
        /// `entries` split at gaps longer than `ChartSeries.maxGap`, one line each.
        var segments: [[HistoryEntry]] = []
        var events: [HistoryEvent] = []
        var acSpans: [ClosedRange<Date>] = []
        var summary: ChartSeries.RangeSummary?
    }

    var body: some View {
        Group {
            if visible { content }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(WindowVisibilityObserver { isVisible in
            visible = isVisible
            if isVisible {
                rebuildSeries()
            } else {
                series = PreparedSeries()
                hoverDate = nil
            }
        })
        .onChange(of: range) { rebuildSeries() }
        .onChange(of: viewModel.history.entries.last?.timestamp) { rebuildSeries() }
        .onChange(of: viewModel.history.events.count) { rebuildSeries() }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var content: some View {
        // TimelineView keeps the x axis moving while the window stays open.
        TimelineView(.everyMinute) { context in
            let now = context.date
            let domain = now.addingTimeInterval(-range.rawValue)...now
            let hovered = hoverDate.flatMap { ChartSeries.nearest(to: $0, in: series.entries) }

            VStack(alignment: .leading, spacing: 12) {
                toolbar
                summaryLine
                readout(hovered)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if series.entries.isEmpty {
                            ContentUnavailableView(
                                "No readings in this range",
                                systemImage: "chart.xyaxis.line",
                                description: Text("Readings are recorded every 30 seconds while the app runs.")
                            )
                            .frame(height: 200)
                        } else {
                            batteryChart(domain: domain, hovered: hovered)
                            powerChart(domain: domain, hovered: hovered)
                            temperatureChart(domain: domain, hovered: hovered)
                            etaChart(domain: domain, hovered: hovered)
                        }
                    }
                    .padding(.bottom)
                }
            }
            .padding(16)
        }
    }

    private func rebuildSeries() {
        guard visible else { return }
        let raw = viewModel.history.entries(in: range.rawValue)
        let segments = ChartSeries.chartSegments(raw, range: range.rawValue, maxPoints: ChartSeries.maxPoints)
        let entries = segments.flatMap { $0 }
        series = PreparedSeries(
            entries: entries,
            segments: segments,
            events: viewModel.history.events(in: range.rawValue).filter { ChartSeries.markedEventKinds.contains($0.kind) },
            acSpans: ChartSeries.acSpans(entries),
            summary: ChartSeries.summary(raw)
        )
    }

    // MARK: - Toolbar and readout

    private var toolbar: some View {
        HStack {
            Picker("Range", selection: $range) {
                ForEach(StatisticsRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([viewModel.history.directoryURL])
            }
            Button("Export CSV") { exportCSV() }
        }
    }

    @ViewBuilder
    private var summaryLine: some View {
        if let summary = series.summary {
            let parts: [String] = [
                summary.drainPercentPerHour.map { String(format: "Drain %.1f%% / h", $0) },
                summary.averageSystemWatts.map { "Avg. system \(Formatting.watts($0))" },
                summary.energyWattHours.map { String(format: "Energy %.1f Wh", $0) },
                "On battery \(Formatting.duration(summary.batterySeconds))",
            ].compactMap { $0 }
            Text("\(range.label) summary:   " + parts.joined(separator: "   "))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func readout(_ entry: HistoryEntry?) -> some View {
        if let entry {
            let parts: [(String, Color)] = [
                ("\(entry.percentage)%", ChartPalette.level),
                entry.batteryWatts.map { ("Battery \(Formatting.batteryFlow($0))", ChartPalette.flow($0)) },
                entry.systemWatts.map { ("System \(Formatting.watts($0))", ChartPalette.system) },
                entry.adapterInputWatts.map { ("Adapter \(Formatting.watts($0))", ChartPalette.adapter) },
                entry.temperatureCelsius.map { (Formatting.temperature($0), ChartPalette.temperature) },
                entry.timeToThreshold.map { ("Sleep in \(Formatting.duration($0))", ChartPalette.eta) },
            ].compactMap { $0 }
            parts.reduce(Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).bold()) { text, part in
                text + Text("   ") + Self.swatch(part.1) + Text(" " + part.0)
            }
            .font(.callout.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Hover a chart to read the values at that time. Green bands are AC power.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Charts

    private func section<Content: View>(_ title: String, legend: [(String, Color)] = [], @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(.headline)
                ForEach(legend, id: \.0) { item in
                    Label {
                        Text(item.0)
                    } icon: {
                        Circle().fill(item.1).frame(width: 8, height: 8)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            content()
                .frame(height: 160)
                .chartOverlay { proxy in hoverOverlay(proxy) }
        }
    }

    private func batteryChart(domain: ClosedRange<Date>, hovered: HistoryEntry?) -> some View {
        section("Battery") {
            Chart {
                acBands
                ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { entry in
                        LineMark(x: .value("Time", entry.timestamp), y: .value("Battery", entry.percentage), series: .value("Segment", index))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(ChartPalette.level)
                    }
                }
                RuleMark(y: .value("Threshold", viewModel.settings.thresholdPercentage))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                eventMarks
                if let hovered {
                    hoverMarks(at: hovered.timestamp, y: Double(hovered.percentage), color: ChartPalette.level,
                               label: Self.valueText("\(hovered.percentage)%", ChartPalette.level))
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("%")
            .chartXScale(domain: domain)
        }
    }

    private func powerChart(domain: ClosedRange<Date>, hovered: HistoryEntry?) -> some View {
        let flows = series.entries.compactMap(\.batteryWatts)
        let loads = series.entries.compactMap(\.systemWatts) + series.entries.compactMap(\.adapterInputWatts)
        let low = min(0, flows.min() ?? 0) * 1.1 - 1
        let high = max(0, flows.max() ?? 0, loads.max() ?? 0) * 1.1 + 1
        // Fraction of the plot height above zero, so the gradient flips colour exactly at 0 W.
        let zeroStop = high / (high - low)
        let flowGradient = LinearGradient(
            stops: [
                .init(color: ChartPalette.charge, location: 0),
                .init(color: ChartPalette.charge, location: zeroStop),
                .init(color: ChartPalette.discharge, location: zeroStop),
                .init(color: ChartPalette.discharge, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )

        return section("Power", legend: [
            ("Into battery", ChartPalette.charge), ("From battery", ChartPalette.discharge),
            ("System load", ChartPalette.system), ("From adapter", ChartPalette.adapter),
        ]) {
            Chart {
                acBands
                ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { entry in
                        if let watts = entry.batteryWatts {
                            AreaMark(x: .value("Time", entry.timestamp), yStart: .value("Zero", 0), yEnd: .value("Battery", watts), series: .value("Series", "Battery \(index)"))
                                .foregroundStyle(flowGradient.opacity(0.3))
                            LineMark(x: .value("Time", entry.timestamp), y: .value("Battery", watts), series: .value("Series", "Battery \(index)"))
                                .foregroundStyle(flowGradient)
                        }
                        if let watts = entry.systemWatts {
                            LineMark(x: .value("Time", entry.timestamp), y: .value("System", watts), series: .value("Series", "System \(index)"))
                                .foregroundStyle(ChartPalette.system)
                        }
                        if let watts = entry.adapterInputWatts {
                            LineMark(x: .value("Time", entry.timestamp), y: .value("Adapter", watts), series: .value("Series", "Adapter \(index)"))
                                .foregroundStyle(ChartPalette.adapter)
                        }
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.6))
                eventMarks
                if let hovered {
                    let parts: [Text] = [
                        hovered.batteryWatts.map { Self.valueText("Battery \(Formatting.batteryFlow($0))", ChartPalette.flow($0)) },
                        hovered.systemWatts.map { Self.valueText("System \(Formatting.watts($0))", ChartPalette.system) },
                        hovered.adapterInputWatts.map { Self.valueText("Adapter \(Formatting.watts($0))", ChartPalette.adapter) },
                    ].compactMap { $0 }
                    let label = parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text("\n") + $1 }
                    hoverMarks(at: hovered.timestamp, y: hovered.systemWatts ?? hovered.batteryWatts ?? 0, color: ChartPalette.system, label: label)
                }
            }
            .chartYScale(domain: low...high)
            .chartYAxisLabel("W")
            .chartXScale(domain: domain)
        }
    }

    private func temperatureChart(domain: ClosedRange<Date>, hovered: HistoryEntry?) -> some View {
        section("Battery temperature") {
            Chart {
                acBands
                ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { entry in
                        if let celsius = entry.temperatureCelsius {
                            LineMark(x: .value("Time", entry.timestamp), y: .value("Temperature", celsius), series: .value("Segment", index))
                                .foregroundStyle(ChartPalette.temperature)
                        }
                    }
                }
                eventMarks
                if let hovered, let celsius = hovered.temperatureCelsius {
                    hoverMarks(at: hovered.timestamp, y: celsius, color: ChartPalette.temperature,
                               label: Self.valueText(Formatting.temperature(celsius), ChartPalette.temperature))
                }
            }
            .chartYAxisLabel("C")
            .chartXScale(domain: domain)
        }
    }

    private func etaChart(domain: ClosedRange<Date>, hovered: HistoryEntry?) -> some View {
        section("Estimated time until threshold") {
            Chart {
                acBands
                ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { entry in
                        if let eta = entry.timeToThreshold {
                            LineMark(x: .value("Time", entry.timestamp), y: .value("Hours", eta / 3600), series: .value("Segment", index))
                                .foregroundStyle(ChartPalette.eta)
                        }
                    }
                }
                eventMarks
                if let hovered, let eta = hovered.timeToThreshold {
                    hoverMarks(at: hovered.timestamp, y: eta / 3600, color: ChartPalette.eta,
                               label: Self.valueText(Formatting.duration(eta), ChartPalette.eta))
                }
            }
            .chartYAxisLabel("h")
            .chartXScale(domain: domain)
        }
    }

    // MARK: - Shared marks

    @ChartContentBuilder
    private var acBands: some ChartContent {
        ForEach(Array(series.acSpans.enumerated()), id: \.offset) { _, span in
            RectangleMark(xStart: .value("Plugged in", span.lowerBound), xEnd: .value("Unplugged", span.upperBound))
                .foregroundStyle(ChartPalette.charge.opacity(0.08))
        }
    }

    @ChartContentBuilder
    private var eventMarks: some ChartContent {
        // Labels of events closer than 4% of the range step down so they stay readable.
        let levels = ChartSeries.labelLevels(for: series.events.map(\.timestamp), minimumGap: range.rawValue * 0.04)
        ForEach(Array(zip(series.events, levels)), id: \.0.id) { event, level in
            RuleMark(x: .value("Time", event.timestamp))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(
                    position: .topTrailing, alignment: .leading, spacing: 2 + CGFloat(level) * 13,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(ChartSeries.label(for: event.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// A small coloured dot that can be concatenated into a `Text`.
    private static func swatch(_ color: Color) -> Text {
        Text(Image(systemName: "circle.fill")).foregroundStyle(color).font(.caption2)
    }

    /// One value in the colour of its series.
    private static func valueText(_ string: String, _ color: Color) -> Text {
        Text(string).foregroundStyle(color).bold()
    }

    @ChartContentBuilder
    private func hoverMarks(at date: Date, y: Double, color: Color, label: Text) -> some ChartContent {
        RuleMark(x: .value("Hover", date))
            .foregroundStyle(.primary.opacity(0.5))
        PointMark(x: .value("Hover", date), y: .value("Value", y))
            .symbolSize(50)
            .foregroundStyle(color)
            .annotation(
                position: .topTrailing, alignment: .leading,
                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
            ) {
                (Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    + Text("\n") + label)
                    .font(.caption.monospacedDigit())
                    .padding(4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
    }

    /// Tracks the mouse over the plot area and converts its x position to a date.
    private func hoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        hoverDate = proxy.value(atX: x, as: Date.self)
                    case .ended:
                        hoverDate = nil
                    }
                }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battery-history-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.history.exportCSV(range: range.rawValue).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
