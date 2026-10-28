import XCTest
@testable import BatterySleepGuard

final class ProcessUsageCalculatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snap(_ seconds: TimeInterval, _ samples: [Int32: ProcessSample]) -> ProcessSnapshot {
        ProcessSnapshot(date: t0.addingTimeInterval(seconds), samples: samples)
    }

    private func sample(_ name: String, cpu: Double, wakeups: UInt64 = 0) -> ProcessSample {
        ProcessSample(name: name, cpuSeconds: cpu, idleWakeups: wakeups)
    }

    func testSharesPercentAndWatts() {
        let older = snap(0, [1: sample("a", cpu: 10), 2: sample("b", cpu: 5)])
        // Over 100 s: a used 30 s of CPU, b used 10 s.
        let newer = snap(100, [1: sample("a", cpu: 40), 2: sample("b", cpu: 15)])
        let usage = ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: 8, minimumCPUPercent: 0.5, limit: 10)
        XCTAssertEqual(usage.map(\.name), ["a", "b"])
        XCTAssertEqual(usage[0].pid, 1)
        XCTAssertEqual(usage[0].cpuPercent, 30, accuracy: 0.001)
        XCTAssertEqual(usage[0].cpuShare, 0.75, accuracy: 0.001)
        XCTAssertEqual(usage[0].approxWatts!, 6, accuracy: 0.001)
        XCTAssertEqual(usage[1].approxWatts!, 2, accuracy: 0.001)
    }

    func testMinimumFilterAndLimit() {
        var older: [Int32: ProcessSample] = [:]
        var newer: [Int32: ProcessSample] = [:]
        for pid in Int32(1)...12 {
            older[pid] = sample("p\(pid)", cpu: 0)
            newer[pid] = sample("p\(pid)", cpu: Double(pid))   // 1% to 12% over 100 s
        }
        older[13] = sample("tiny", cpu: 0)
        newer[13] = sample("tiny", cpu: 0.2)   // 0.2%, hidden
        let usage = ProcessUsageCalculator.usage(from: snap(0, older), to: snap(100, newer), attributableWatts: nil, minimumCPUPercent: 0.5, limit: 10)
        XCTAssertEqual(usage.count, 10)
        XCTAssertEqual(usage.first?.name, "p12")
        XCTAssertFalse(usage.contains { $0.name == "tiny" })
        XCTAssertNil(usage.first?.approxWatts)
    }

    func testPidReuseWithDifferentNameIsSkipped() {
        let older = snap(0, [7: sample("old", cpu: 500)])
        let newer = snap(100, [7: sample("new", cpu: 3)])
        XCTAssertTrue(ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: nil, minimumCPUPercent: 0, limit: 10).isEmpty)
    }

    func testProcessMissingFromNewerSnapshotIsIgnored() {
        let older = snap(0, [1: sample("gone", cpu: 10), 2: sample("stays", cpu: 0)])
        let newer = snap(100, [2: sample("stays", cpu: 50)])
        let usage = ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: nil, minimumCPUPercent: 0, limit: 10)
        XCTAssertEqual(usage.map(\.name), ["stays"])
        XCTAssertEqual(usage[0].cpuShare, 1, accuracy: 0.001)
    }

    func testWakeupsPerSecond() {
        let older = snap(0, [1: sample("a", cpu: 0, wakeups: 100)])
        let newer = snap(50, [1: sample("a", cpu: 10, wakeups: 600)])
        let usage = ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: nil, minimumCPUPercent: 0, limit: 10)
        XCTAssertEqual(usage[0].idleWakeupsPerSecond, 10, accuracy: 0.001)
    }

    func testZeroWindowGivesEmpty() {
        let snapshot = snap(0, [1: sample("a", cpu: 1)])
        XCTAssertTrue(ProcessUsageCalculator.usage(from: snapshot, to: snapshot, attributableWatts: nil, minimumCPUPercent: 0, limit: 10).isEmpty)
    }

    func testAttributableWattsNeverNegativeAndNilWhenNothingToAttribute() {
        XCTAssertNil(ProcessUsageCalculator.attributableWatts(averageLoad: nil, idleFloor: 5))
        XCTAssertEqual(ProcessUsageCalculator.attributableWatts(averageLoad: 20, idleFloor: 6)!, 14, accuracy: 0.001)
        // Load at or below the floor: no confident "0.0 W", the column shows "-" instead.
        XCTAssertNil(ProcessUsageCalculator.attributableWatts(averageLoad: 5, idleFloor: 6))
        XCTAssertNil(ProcessUsageCalculator.attributableWatts(averageLoad: 6.3, idleFloor: 6))
        XCTAssertEqual(ProcessUsageCalculator.attributableWatts(averageLoad: 20, idleFloor: nil)!, 20, accuracy: 0.001)
    }

    func testSystemWideTotalLeavesUnreadableShareUnattributed() {
        // System-wide busy CPU over the window is 100 s, the one readable process used 25 s,
        // so the other 75 s belong to processes the app cannot see and get no watts.
        var older = snap(0, [1: sample("a", cpu: 0)])
        older.systemCPUSeconds = 1000
        var newer = snap(100, [1: sample("a", cpu: 25)])
        newer.systemCPUSeconds = 1100
        let usage = ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: 8, minimumCPUPercent: 0, limit: 10)
        XCTAssertEqual(usage[0].cpuShare, 0.25, accuracy: 0.001)
        XCTAssertEqual(usage[0].approxWatts!, 2, accuracy: 0.001)

        // Tick granularity can put the system total below the readable sum: never exceed 100%.
        newer.systemCPUSeconds = 1010
        let clamped = ProcessUsageCalculator.usage(from: older, to: newer, attributableWatts: 8, minimumCPUPercent: 0, limit: 10)
        XCTAssertEqual(clamped[0].cpuShare, 1, accuracy: 0.001)
    }
}

final class ProcessSamplerTests: XCTestCase {
    func testMachTicksToSeconds() {
        // Apple Silicon timebase: 125 / 3 nanoseconds per tick, so 24_000 ticks are 1 ms.
        let timebase = mach_timebase_info(numer: 125, denom: 3)
        XCTAssertEqual(ProcessSampler.seconds(machTicks: 24_000, timebase: timebase), 0.001, accuracy: 1e-9)
        XCTAssertEqual(ProcessSampler.seconds(machTicks: 0, timebase: timebase), 0)
        // Intel timebase 1 / 1: ticks are nanoseconds.
        XCTAssertEqual(ProcessSampler.seconds(machTicks: 2_000_000_000, timebase: mach_timebase_info(numer: 1, denom: 1)), 2, accuracy: 1e-9)
    }

    func testLiveSnapshotContainsThisProcess() {
        let snapshot = ProcessSampler.snapshot(now: Date())
        let me = snapshot.samples[getpid()]
        XCTAssertNotNil(me, "the test host itself must be readable")
        XCTAssertFalse(me?.name.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(me?.cpuSeconds ?? -1, 0)
        XCTAssertGreaterThan(snapshot.samples.count, 10)
        XCTAssertGreaterThan(snapshot.systemCPUSeconds ?? 0, 0, "system-wide busy CPU time from host_statistics")
    }
}
