import XCTest
@testable import BatterySleepGuard

final class HistoryCSVTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000.5)

    private func entry(
        seconds: TimeInterval = 0, percentage: Int = 50,
        batteryWatts: Double? = -13.456, systemWatts: Double? = 15.2, temperature: Double? = 31.25,
        rate: Double? = 8.5, eta: TimeInterval? = 5400
    ) -> HistoryEntry {
        HistoryEntry(
            timestamp: date.addingTimeInterval(seconds), percentage: percentage, powerSource: .battery, isCharging: false,
            batteryWatts: batteryWatts, systemWatts: systemWatts, temperatureCelsius: temperature,
            drainPercentPerHour: rate, timeToThreshold: eta, keepAwakeHolding: true, status: "monitoring"
        )
    }

    func testEntryRoundTrip() throws {
        let original = entry()
        let line = HistoryCSV.line(for: original)
        let parsed = try XCTUnwrap(HistoryCSV.entry(from: line))
        XCTAssertEqual(parsed.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(parsed.percentage, 50)
        XCTAssertEqual(parsed.powerSource, .battery)
        XCTAssertFalse(parsed.isCharging)
        XCTAssertEqual(parsed.batteryWatts!, -13.456, accuracy: 0.001)
        XCTAssertEqual(parsed.systemWatts!, 15.2, accuracy: 0.001)
        XCTAssertEqual(parsed.temperatureCelsius!, 31.25, accuracy: 0.001)
        XCTAssertEqual(parsed.drainPercentPerHour!, 8.5, accuracy: 0.001)
        XCTAssertEqual(parsed.timeToThreshold!, 5400, accuracy: 0.001)
        XCTAssertTrue(parsed.keepAwakeHolding)
        XCTAssertEqual(parsed.status, "monitoring")
    }

    func testEntryWithNilFieldsRoundTrip() throws {
        let original = entry(batteryWatts: nil, systemWatts: nil, temperature: nil, rate: nil, eta: nil)
        let line = HistoryCSV.line(for: original)
        XCTAssertTrue(line.contains(",,,,,"), "nil fields are empty columns: \(line)")
        let parsed = try XCTUnwrap(HistoryCSV.entry(from: line))
        XCTAssertNil(parsed.batteryWatts)
        XCTAssertNil(parsed.systemWatts)
        XCTAssertNil(parsed.temperatureCelsius)
        XCTAssertNil(parsed.drainPercentPerHour)
        XCTAssertNil(parsed.timeToThreshold)
    }

    func testAdapterInputRoundTripsAndLegacyRowsStillLoad() throws {
        var original = entry()
        original.adapterInputWatts = 63.25
        let parsed = try XCTUnwrap(HistoryCSV.entry(from: HistoryCSV.line(for: original)))
        XCTAssertEqual(parsed.adapterInputWatts!, 63.25, accuracy: 0.001)

        // Rows written before the column existed have 11 fields.
        let legacy = "2026-10-02T10:54:39.260Z,59,ac,true,54.372,28.334,36.290,,,false,onACPower"
        let old = try XCTUnwrap(HistoryCSV.entry(from: legacy))
        XCTAssertEqual(old.percentage, 59)
        XCTAssertNil(old.adapterInputWatts)
    }

    func testPowerSourceEvents() {
        func reading(_ source: PowerSource, adapter: Int? = nil) -> BatteryReading {
            BatteryReading(timestamp: date, percentage: 50, isCharging: source == .ac, isCharged: false, powerSource: source,
                           telemetry: BatteryTelemetry(adapterWatts: adapter))
        }
        XCTAssertNil(HistoryEvent.powerSourceEvent(previous: nil, reading: reading(.battery)))
        XCTAssertNil(HistoryEvent.powerSourceEvent(previous: .battery, reading: reading(.battery)))
        let plugged = HistoryEvent.powerSourceEvent(previous: .battery, reading: reading(.ac, adapter: 96))
        XCTAssertEqual(plugged?.kind, .pluggedIn)
        XCTAssertEqual(plugged?.message, "96 W adapter")
        let unplugged = HistoryEvent.powerSourceEvent(previous: .ac, reading: reading(.battery))
        XCTAssertEqual(unplugged?.kind, .unplugged)
        XCTAssertTrue(ChartSeries.markedEventKinds.contains(.pluggedIn))
        XCTAssertEqual(ChartSeries.label(for: .unplugged), "Unplugged")
    }

    func testEntryHeaderColumnCountMatchesLine() {
        let header = HistoryCSV.entryHeader.split(separator: ",").count
        let columns = HistoryCSV.fields(from: HistoryCSV.line(for: entry())).count
        XCTAssertEqual(header, columns)
    }

    func testEventRoundTripWithQuotedMessage() throws {
        let original = HistoryEvent(timestamp: date, kind: .sleepFailed, message: "pmset said \"no\", try again\nlater")
        let line = HistoryCSV.line(for: original)
        XCTAssertFalse(line.contains("\n"), "newlines inside a field must be escaped or replaced: \(line)")
        let parsed = try XCTUnwrap(HistoryCSV.event(from: line))
        XCTAssertEqual(parsed.kind, .sleepFailed)
        XCTAssertEqual(parsed.message, "pmset said \"no\", try again later")
        XCTAssertEqual(parsed.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMalformedLinesAreSkipped() {
        XCTAssertNil(HistoryCSV.entry(from: ""))
        XCTAssertNil(HistoryCSV.entry(from: "not-a-date,50,battery,false,,,,,,true,monitoring"))
        XCTAssertNil(HistoryCSV.entry(from: "2024-01-01T00:00:00.000Z,50,battery"))
        XCTAssertNil(HistoryCSV.entry(from: HistoryCSV.entryHeader))
        XCTAssertNil(HistoryCSV.event(from: "2024-01-01T00:00:00.000Z,unknownKind,hello"))
    }

    func testTimestampParserMatchesWrittenFormat() throws {
        let text = HistoryCSV.fields(from: HistoryCSV.line(for: entry()))[0]
        let parsed = try XCTUnwrap(HistoryCSV.timestamp(from: text))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(HistoryCSV.timestamp(from: "1970-01-01T00:00:00.000Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(HistoryCSV.timestamp(from: "2024-03-01T12:30:15.250Z")?.timeIntervalSince1970, 1_709_296_215.25)
        XCTAssertNil(HistoryCSV.timestamp(from: "2024-13-01T00:00:00.000Z"))
        XCTAssertNil(HistoryCSV.timestamp(from: "2024-01-01T00:00:00Z"))
        XCTAssertNil(HistoryCSV.timestamp(from: "2024-01-01 00:00:00.000Z"))
    }

    func testEventsWithSameTimestampHaveDistinctIDs() {
        let wake = HistoryEvent(timestamp: date, kind: .wake, message: "")
        let reset = HistoryEvent(timestamp: date, kind: .cycleReset, message: "")
        XCTAssertNotEqual(wake.id, reset.id)
    }

    func testFieldsSplitsQuotedCommas() {
        XCTAssertEqual(HistoryCSV.fields(from: "a,\"b,c\",\"d\"\"e\",,f"), ["a", "b,c", "d\"e", "", "f"])
    }

    func testEntryFromReadingUsesDrainEstimate() {
        let reading = BatteryReading(
            timestamp: date, percentage: 42, isCharging: false, isCharged: false, powerSource: .battery,
            telemetry: BatteryTelemetry(batteryWatts: -10, systemWatts: 12, temperatureCelsius: 30, adapterWatts: nil)
        )
        let entry = HistoryEntry(reading: reading, estimate: .draining(percentPerHour: 6, timeToThreshold: 1800), keepAwakeHolding: false, status: "monitoring")
        XCTAssertEqual(entry.percentage, 42)
        XCTAssertEqual(entry.batteryWatts, -10)
        XCTAssertEqual(entry.drainPercentPerHour, 6)
        XCTAssertEqual(entry.timeToThreshold, 1800)

        let flat = HistoryEntry(reading: reading, estimate: .notDecreasing, keepAwakeHolding: false, status: "monitoring")
        XCTAssertNil(flat.drainPercentPerHour)
        XCTAssertNil(flat.timeToThreshold)
    }
}

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(retention: TimeInterval = HistoryStore.retention) -> HistoryStore {
        HistoryStore(directory: directory, retention: retention, now: { self.clock })
    }

    private func entry(seconds: TimeInterval, percentage: Int = 50, charging: Bool = false) -> HistoryEntry {
        HistoryEntry(
            timestamp: clock.addingTimeInterval(seconds), percentage: percentage, powerSource: .battery, isCharging: charging,
            batteryWatts: -10, systemWatts: 12, temperatureCelsius: 30, drainPercentPerHour: nil, timeToThreshold: nil,
            keepAwakeHolding: false, status: "monitoring"
        )
    }

    func testUnchangedReadingWithinIntervalIsSkipped() {
        let first = entry(seconds: 0)
        XCTAssertTrue(HistoryStore.shouldRecord(first, after: nil, minimumInterval: 30))
        XCTAssertFalse(HistoryStore.shouldRecord(entry(seconds: 5), after: first, minimumInterval: 30))
        XCTAssertTrue(HistoryStore.shouldRecord(entry(seconds: 30), after: first, minimumInterval: 30))
    }

    func testChangedReadingIsRecordedImmediately() {
        let first = entry(seconds: 0)
        XCTAssertTrue(HistoryStore.shouldRecord(entry(seconds: 5, percentage: 49), after: first, minimumInterval: 30))
        XCTAssertTrue(HistoryStore.shouldRecord(entry(seconds: 5, charging: true), after: first, minimumInterval: 30))
    }

    func testPrunedDropsOlderThanCutoff() {
        let items = [entry(seconds: -100), entry(seconds: -50), entry(seconds: 0)]
        let kept = HistoryStore.pruned(items, cutoff: clock.addingTimeInterval(-50), timestamp: \.timestamp)
        XCTAssertEqual(kept.map(\.timestamp), [items[1].timestamp, items[2].timestamp])
    }

    func testRecordAppendsToMemoryAndFile() throws {
        let store = makeStore()
        store.record(entry(seconds: 0))
        store.record(entry(seconds: 5))   // throttled
        store.record(entry(seconds: 60))
        store.record(HistoryEvent(timestamp: clock, kind: .launch, message: "App started"))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.events.count, 1)

        let history = try String(contentsOf: directory.appending(path: "history.csv"), encoding: .utf8)
        let lines = history.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[0]), HistoryCSV.entryHeader)

        let events = try String(contentsOf: directory.appending(path: "events.csv"), encoding: .utf8)
        XCTAssertEqual(events.split(separator: "\n").count, 2)
    }

    func testReloadRestoresRowsAndPrunesExpired() throws {
        let store = makeStore(retention: 3600)
        store.record(entry(seconds: -7200))
        store.record(entry(seconds: -1800))
        store.record(HistoryEvent(timestamp: clock.addingTimeInterval(-7200), kind: .wake, message: "old"))
        store.record(HistoryEvent(timestamp: clock.addingTimeInterval(-60), kind: .wake, message: "recent"))

        let reloaded = makeStore(retention: 3600)
        XCTAssertEqual(reloaded.entries.map(\.percentage), [50])
        XCTAssertEqual(reloaded.entries.first?.timestamp.timeIntervalSince1970 ?? 0, clock.addingTimeInterval(-1800).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.events.map(\.message), ["recent"])

        // The file was rewritten without the expired rows.
        let history = try String(contentsOf: directory.appending(path: "history.csv"), encoding: .utf8)
        XCTAssertEqual(history.split(separator: "\n").count, 2)
    }

    func testLoadSkipsMalformedLinesAndKeepsValidRows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = HistoryCSV.line(for: entry(seconds: -10))
        let contents = [HistoryCSV.entryHeader, "garbage,line", good, "2024-01-01T00:00:00.000Z,50,batt"].joined(separator: "\n") + "\n"
        try contents.write(to: directory.appending(path: "history.csv"), atomically: true, encoding: .utf8)

        let store = makeStore()
        XCTAssertEqual(store.entries.count, 1)
        // A later record still appends after the rewrite.
        store.record(entry(seconds: 0, percentage: 49))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.percentage), [50, 49])
    }

    func testRangeQueriesAndExport() {
        let store = makeStore()
        store.record(entry(seconds: -7200, percentage: 60))
        store.record(entry(seconds: -600, percentage: 55))
        store.record(entry(seconds: 0, percentage: 54))
        store.record(HistoryEvent(timestamp: clock.addingTimeInterval(-7000), kind: .launch, message: "old"))
        store.record(HistoryEvent(timestamp: clock.addingTimeInterval(-300), kind: .cycleReset, message: "new"))

        XCTAssertEqual(store.entries(in: 3600).map(\.percentage), [55, 54])
        XCTAssertEqual(store.events(in: 3600).map(\.message), ["new"])

        let csv = store.exportCSV(range: 3600)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[0]), HistoryCSV.entryHeader)
        XCTAssertTrue(lines[1].contains(",55,"))
    }

    func testExpiredRowsAreRewrittenOutOfFileWhileRunning() throws {
        let store = makeStore(retention: 3600)
        store.record(entry(seconds: 0))
        clock = clock.addingTimeInterval(2 * 3600)
        store.record(entry(seconds: 0, percentage: 49))

        XCTAssertEqual(store.entries.map(\.percentage), [49])
        let history = try String(contentsOf: directory.appending(path: "history.csv"), encoding: .utf8)
        XCTAssertEqual(history.split(separator: "\n").count, 2, "file holds header plus the one live row")
    }

    func testRewriteByAnotherInstanceKeepsThisHandleValid() throws {
        let first = makeStore()
        first.record(entry(seconds: -10))
        // A second instance with a 1 s retention drops that row and rewrites the file.
        let second = makeStore(retention: 1)
        XCTAssertEqual(second.entries.count, 0)

        first.record(entry(seconds: 60, percentage: 49))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.percentage), [49])
    }

    func testWriteFailureDoesNotThrowAndKeepsMemoryState() throws {
        // A regular file where the directory should be makes directory creation fail.
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: directory)

        let store = makeStore()
        store.record(entry(seconds: 0))
        store.record(HistoryEvent(timestamp: clock, kind: .launch, message: "x"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.events.count, 1)
    }
}

final class ChartSeriesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ index: Int, watts: Double?) -> HistoryEntry {
        HistoryEntry(
            timestamp: start.addingTimeInterval(TimeInterval(index * 30)), percentage: 100 - index, powerSource: .battery, isCharging: false,
            batteryWatts: watts, systemWatts: nil, temperatureCelsius: Double(index), drainPercentPerHour: nil, timeToThreshold: nil,
            keepAwakeHolding: false, status: "monitoring"
        )
    }

    func testSmallSeriesIsUnchanged() {
        let entries = (0..<10).map { entry($0, watts: -10) }
        XCTAssertEqual(ChartSeries.downsample(entries, maxPoints: 600), entries)
    }

    func testDownsampleCapsPointCount() {
        let entries = (0..<20_000).map { entry($0, watts: -10) }
        let result = ChartSeries.downsample(entries, maxPoints: 600)
        XCTAssertLessThanOrEqual(result.count, 600)
        XCTAssertGreaterThan(result.count, 500)
        XCTAssertEqual(result.first?.timestamp, entries.first?.timestamp)
    }

    func testDownsampleAveragesNumericFieldsAndIgnoresNil() {
        let entries = [entry(0, watts: -10), entry(1, watts: nil), entry(2, watts: -20), entry(3, watts: -30)]
        let result = ChartSeries.downsample(entries, maxPoints: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].batteryWatts!, -10, accuracy: 0.001)   // nil ignored, single value
        XCTAssertEqual(result[1].batteryWatts!, -25, accuracy: 0.001)
        XCTAssertEqual(result[0].temperatureCelsius!, 0.5, accuracy: 0.001)
        XCTAssertEqual(result[0].percentage, 100)   // (100 + 99) / 2 rounded
        XCTAssertEqual(result[0].timestamp, entries[0].timestamp)
        XCTAssertEqual(result[1].timestamp, entries[2].timestamp)
    }

    func testACSpansCoverRunsOfACRows() {
        var entries = (0..<8).map { entry($0, watts: -10) }
        for index in [2, 3, 6, 7] { entries[index].powerSource = .ac }
        let spans = ChartSeries.acSpans(entries)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0], entries[2].timestamp...entries[4].timestamp, "ends where the next battery row starts")
        XCTAssertEqual(spans[1], entries[6].timestamp...entries[7].timestamp, "open run ends at the last row")
        XCTAssertTrue(ChartSeries.acSpans([]).isEmpty)
    }

    func testNearestEntryByTime() {
        let entries = (0..<5).map { entry($0, watts: -10) }   // 30 s apart
        XCTAssertEqual(ChartSeries.nearest(to: start.addingTimeInterval(44), in: entries)?.timestamp, entries[1].timestamp)
        XCTAssertEqual(ChartSeries.nearest(to: start.addingTimeInterval(46), in: entries)?.timestamp, entries[2].timestamp)
        XCTAssertEqual(ChartSeries.nearest(to: start.addingTimeInterval(-500), in: entries)?.timestamp, entries[0].timestamp)
        XCTAssertNil(ChartSeries.nearest(to: start, in: []))
    }

    func testLabelLevelsStaggerCloseEvents() {
        let dates = [0.0, 10, 20, 500, 505].map { start.addingTimeInterval($0) }
        XCTAssertEqual(ChartSeries.labelLevels(for: dates, minimumGap: 60), [0, 1, 2, 0, 1])
        XCTAssertEqual(ChartSeries.labelLevels(for: [], minimumGap: 60), [])
    }

    func testEventLabels() {
        XCTAssertEqual(ChartSeries.label(for: .sleepTriggered), "Sleep")
        XCTAssertTrue(ChartSeries.markedEventKinds.contains(.wake))
        XCTAssertFalse(ChartSeries.markedEventKinds.contains(.batteryError))
    }
}


final class FormattingTests: XCTestCase {
    func testBatteryStateText() {
        XCTAssertEqual(Formatting.batteryState(-17.24), "17.2 W out, discharging")
        XCTAssertEqual(Formatting.batteryState(44.0), "44.0 W in, charging")
        XCTAssertEqual(Formatting.batteryState(0.02), "Idle")
    }
}
