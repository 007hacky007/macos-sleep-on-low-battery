import XCTest
@testable import BatterySleepGuard

// MARK: - Task 1: settings and policy

final class KeepAwakeOnlyOnACTests: XCTestCase {
    private func reading(_ source: PowerSource) -> BatteryReading {
        BatteryReading(timestamp: Date(), percentage: 80, isCharging: source == .ac, isCharged: false, powerSource: source)
    }

    func testKeepAwakeOnlyOnACSuspendsOnBattery() {
        var settings = AppSettings()
        settings.keepAwakeOnlyOnAC = true
        XCTAssertFalse(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(.battery)))
        XCTAssertTrue(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(.ac)))
        settings.keepAwakeOnlyOnAC = false
        XCTAssertTrue(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(.battery)))
    }
}

final class EarlyWarningPolicyTests: XCTestCase {
    func testWarnsOnceInsideLeadTime() {
        let now = Date()
        let lead: TimeInterval = 10 * 60
        XCTAssertFalse(SleepTriggerPolicy.shouldWarn(estimatedSleepDate: now.addingTimeInterval(20 * 60), now: now, leadTime: lead, alreadyWarned: false))
        XCTAssertTrue(SleepTriggerPolicy.shouldWarn(estimatedSleepDate: now.addingTimeInterval(9 * 60), now: now, leadTime: lead, alreadyWarned: false))
        XCTAssertFalse(SleepTriggerPolicy.shouldWarn(estimatedSleepDate: now.addingTimeInterval(9 * 60), now: now, leadTime: lead, alreadyWarned: true))
        XCTAssertFalse(SleepTriggerPolicy.shouldWarn(estimatedSleepDate: nil, now: now, leadTime: lead, alreadyWarned: false))
        XCTAssertFalse(SleepTriggerPolicy.shouldWarn(estimatedSleepDate: now.addingTimeInterval(-60), now: now, leadTime: lead, alreadyWarned: false), "already past: no warning")
    }
}

final class EarlyWarningResetTests: XCTestCase {
    func testPluggingInResetsTheWarning() {
        XCTAssertTrue(SleepTriggerPolicy.clearsEarlyWarning(.pluggedIn))
        XCTAssertFalse(SleepTriggerPolicy.clearsEarlyWarning(.unplugged))
        XCTAssertFalse(SleepTriggerPolicy.clearsEarlyWarning(.wake))
    }
}

final class SettingsPersistenceTests: XCTestCase {
    func testNewSettingsRoundTripAndDefaults() {
        let defaults = UserDefaults(suiteName: "SettingsPersistenceTests-\(UUID().uuidString)")!
        let persistence = PersistenceService(defaults: defaults)
        var settings = AppSettings()
        settings.historyRetentionDays = 30
        settings.keepAwakeOnlyOnAC = true
        settings.earlyWarning = false
        settings.menuBarText = .batteryAndTimeToSleep
        persistence.save(settings)

        let loaded = persistence.loadSettings()
        XCTAssertEqual(loaded.historyRetentionDays, 30)
        XCTAssertTrue(loaded.keepAwakeOnlyOnAC)
        XCTAssertFalse(loaded.earlyWarning)
        XCTAssertEqual(loaded.menuBarText, .batteryAndTimeToSleep)

        XCTAssertEqual(AppSettings().historyRetentionDays, 7)
        XCTAssertTrue(AppSettings().earlyWarning)
        XCTAssertFalse(AppSettings().keepAwakeOnlyOnAC)
        XCTAssertEqual(AppSettings.retentionChoices, [1, 7, 30])
        XCTAssertTrue(MenuBarText.allCases.contains(.keepAwakeRemaining))
    }
}

// MARK: - Task 2: chart series

final class ChartSeriesTimeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(at seconds: TimeInterval, pct: Int = 50, sys: Double? = 10, source: PowerSource = .battery) -> HistoryEntry {
        HistoryEntry(
            timestamp: start.addingTimeInterval(seconds), percentage: pct, powerSource: source, isCharging: source == .ac,
            batteryWatts: nil, systemWatts: sys, temperatureCelsius: nil, drainPercentPerHour: nil, timeToThreshold: nil,
            keepAwakeHolding: false, status: "monitoring"
        )
    }

    func testSegmentsBreakAtGaps() {
        let entries = [0.0, 30, 60, 1000, 1030, 1060].map { entry(at: $0) }
        XCTAssertEqual(ChartSeries.segments(entries, maxGap: 300).map(\.count), [3, 3])
        XCTAssertTrue(ChartSeries.segments([], maxGap: 300).isEmpty)
        XCTAssertEqual(ChartSeries.segments(entries, maxGap: 2000).map(\.count), [6])
    }

    func testDownsampleBucketsByTime() {
        // Ten rows in the first minute, a gap of an hour, then one row: buckets of 15 minutes
        // must not merge rows across the gap, so the result is two points at the original times.
        var entries = (0..<10).map { entry(at: Double($0) * 6) }
        entries.append(entry(at: 3600))
        let result = ChartSeries.downsample(entries, maxPoints: 4)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].timestamp, entries[0].timestamp)
        XCTAssertEqual(result[1].timestamp, entries[10].timestamp)
    }

    func testChartSegmentsSurviveDownsamplingOverLongSpans() {
        // 60 hours of continuous 5 minute heartbeats: one unbroken line, at most maxPoints rows.
        let entries = (0..<720).map { entry(at: Double($0) * 300) }
        let segments = ChartSeries.chartSegments(entries, range: 7 * 86_400, maxPoints: 600)
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].count, 600)
        XCTAssertGreaterThan(segments[0].count, 100)

        // A real gap still breaks the line, and each side keeps its points.
        let gapped = entries + (0..<720).map { entry(at: 400_000 + Double($0) * 300) }
        let two = ChartSeries.chartSegments(gapped, range: 7 * 86_400, maxPoints: 600)
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(two.allSatisfy { $0.count > 1 })
    }

    func testRangeSummary() {
        // One hour on battery, 60% to 52%, system load 10, 20, 30 W.
        let entries = [entry(at: 0, pct: 60, sys: 10), entry(at: 1800, pct: 56, sys: 20), entry(at: 3600, pct: 52, sys: 30)]
        let summary = try! XCTUnwrap(ChartSeries.summary(entries))
        XCTAssertEqual(summary.drainPercentPerHour!, 8, accuracy: 0.01)
        XCTAssertEqual(summary.energyWattHours!, 20, accuracy: 0.01)      // trapezoid: 15 * 0.5 h + 25 * 0.5 h
        XCTAssertEqual(summary.averageSystemWatts!, 20, accuracy: 0.01)   // time weighted
        XCTAssertEqual(summary.batterySeconds, 3600, accuracy: 0.01)
        XCTAssertNil(ChartSeries.summary([]))

        // A charging stretch neither counts as drain nor as battery time; a pair missing watts is skipped.
        let mixed = [entry(at: 0, pct: 60, sys: nil), entry(at: 1800, pct: 56, sys: 20), entry(at: 3600, pct: 70, sys: 20, source: .ac), entry(at: 5400, pct: 80, sys: 20, source: .ac)]
        let mixedSummary = try! XCTUnwrap(ChartSeries.summary(mixed))
        XCTAssertEqual(mixedSummary.drainPercentPerHour!, 8, accuracy: 0.01)
        XCTAssertEqual(mixedSummary.batterySeconds, 3600, accuracy: 0.01)
        XCTAssertEqual(mixedSummary.energyWattHours!, 20, accuracy: 0.01)   // only the two pairs with watts on both sides: 20 W * 1 h
    }
}

// MARK: - Task 3: history store retention and clearing

@MainActor
final class HistoryStoreRetentionTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreRetentionTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(retention: TimeInterval = HistoryStore.retention) -> HistoryStore {
        HistoryStore(directory: directory, retention: retention, now: { self.clock })
    }

    private func entry(seconds: TimeInterval, percentage: Int = 50) -> HistoryEntry {
        HistoryEntry(
            timestamp: clock.addingTimeInterval(seconds), percentage: percentage, powerSource: .battery, isCharging: false,
            batteryWatts: nil, systemWatts: nil, temperatureCelsius: nil, drainPercentPerHour: nil, timeToThreshold: nil,
            keepAwakeHolding: false, status: "monitoring"
        )
    }

    private func lines(_ name: String) throws -> [String] {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testClearRemovesRowsAndRewritesHeaders() throws {
        let store = makeStore()
        store.record(entry(seconds: 0))
        store.record(HistoryEvent(timestamp: clock, kind: .launch, message: "x"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(try lines("history.csv"), [HistoryCSV.entryHeader])
        XCTAssertEqual(try lines("events.csv"), [HistoryCSV.eventHeader])
        // Recording after a clear appends below the header.
        store.record(entry(seconds: 60, percentage: 49))
        XCTAssertEqual(try lines("history.csv").count, 2)
    }

    func testChangingRetentionPrunesImmediately() throws {
        let store = makeStore()
        store.record(entry(seconds: -3 * 86_400))
        store.record(entry(seconds: 0, percentage: 49))
        store.setRetention(days: 1)
        XCTAssertEqual(store.entries.map(\.percentage), [49])
        XCTAssertEqual(try lines("history.csv").count, 2)
        XCTAssertEqual(store.retentionDays, 1)
    }

    func testStaleHeaderIsRewrittenOnLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldHeader = "timestamp,percentage,powerSource,isCharging,batteryWatts,systemWatts,temperatureCelsius,drainPercentPerHour,timeToThreshold,keepAwakeHolding,status"
        let row = HistoryCSV.line(for: entry(seconds: -10))
        try (oldHeader + "\n" + row + "\n").write(to: directory.appending(path: "history.csv"), atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(try lines("history.csv").first, HistoryCSV.entryHeader)
    }
}

// MARK: - Task 4: process groups

final class ProcessGroupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(_ seconds: TimeInterval, cpu: [Int32: Double], names: [Int32: String], parents: [Int32: Int32]) -> ProcessSnapshot {
        var samples: [Int32: ProcessSample] = [:]
        for (pid, seconds) in cpu { samples[pid] = ProcessSample(name: names[pid] ?? "?", cpuSeconds: seconds, idleWakeups: 0) }
        return ProcessSnapshot(date: t0.addingTimeInterval(seconds), samples: samples, systemCPUSeconds: nil, parents: parents, names: names)
    }

    func testGroupsRollUpThroughUnreadableAncestor() {
        // launchd(1) -> ghostty(100) -> login(101, root, unreadable) -> zsh(102) -> claude(103); launchd -> firefox(200) -> helper(201)
        let names: [Int32: String] = [100: "ghostty", 101: "login", 102: "zsh", 103: "claude", 200: "firefox", 201: "helper"]
        let parents: [Int32: Int32] = [100: 1, 101: 100, 102: 101, 103: 102, 200: 1, 201: 200]
        let older = snapshot(0, cpu: [100: 0, 102: 0, 103: 0, 200: 0, 201: 0], names: names, parents: parents)
        let newer = snapshot(100, cpu: [100: 4, 102: 1, 103: 20, 200: 5, 201: 10], names: names, parents: parents)

        let groups = ProcessUsageCalculator.groups(from: older, to: newer, attributableWatts: 8, minimumCPUPercent: 0.5, limit: 10)
        XCTAssertEqual(groups.map(\.name), ["ghostty", "firefox"])
        XCTAssertEqual(groups[0].id, 100)
        XCTAssertEqual(groups[0].cpuPercent, 25, accuracy: 0.001)
        XCTAssertEqual(groups[0].cpuShare, 0.625, accuracy: 0.001)
        XCTAssertEqual(groups[0].approxWatts!, 5, accuracy: 0.001)
        XCTAssertEqual(groups[0].members.map(\.name), ["claude", "ghostty", "zsh"], "members sorted by CPU")
        XCTAssertEqual(groups[1].members.map(\.name), ["helper", "firefox"])
    }

    func testLiveSnapshotHasParentsForAllProcesses() {
        let snapshot = ProcessSampler.snapshot(now: Date())
        XCTAssertGreaterThan(snapshot.parents.count, snapshot.samples.count, "sysctl covers processes libproc cannot read")
        XCTAssertNotNil(snapshot.parents[getpid()])
        XCTAssertFalse(snapshot.names[getpid()]?.isEmpty ?? true)
    }
}

final class ChartPaletteTests: XCTestCase {
    func testFlowColorFollowsDirection() {
        XCTAssertEqual(ChartPalette.flow(-5), ChartPalette.discharge)
        XCTAssertEqual(ChartPalette.flow(5), ChartPalette.charge)
        XCTAssertEqual(ChartPalette.flow(0), ChartPalette.charge)
        XCTAssertNotEqual(ChartPalette.system, ChartPalette.adapter)
    }
}
