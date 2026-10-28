import IOKit.pwr_mgt
import XCTest
@testable import BatterySleepGuard

final class DrainRateCalculatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ minutes: Double, _ percentage: Int, power: PowerSource = .battery, charging: Bool = false) -> BatterySample {
        BatterySample(timestamp: start.addingTimeInterval(minutes * 60), percentage: percentage, isCharging: charging, powerSource: power)
    }

    private func reading(_ minutes: Double, _ percentage: Int, power: PowerSource = .battery, charging: Bool = false) -> BatteryReading {
        BatteryReading(timestamp: start.addingTimeInterval(minutes * 60), percentage: percentage, isCharging: charging, isCharged: false, powerSource: power)
    }

    func testSteadyDrainGivesRateAndETA() {
        // 8% per hour: one percent every 7.5 minutes.
        let samples = (0..<6).map { sample(Double($0) * 7.5, 65 - $0) }
        let estimate = DrainRateCalculator.estimate(samples: samples, current: reading(37.5, 60), threshold: 25)
        guard case .draining(let rate, let eta?) = estimate else { return XCTFail("got \(estimate)") }
        XCTAssertEqual(rate, 8, accuracy: 0.01)
        XCTAssertEqual(eta, 35.0 / 8 * 3600, accuracy: 1)
    }

    func testChargingReturnsNotOnBattery() {
        let estimate = DrainRateCalculator.estimate(samples: [], current: reading(0, 50, power: .ac, charging: true), threshold: 25)
        XCTAssertEqual(estimate, .notOnBattery)
    }

    func testTooFewSamples() {
        let samples = [sample(0, 60), sample(1, 60)]
        XCTAssertEqual(DrainRateCalculator.estimate(samples: samples, current: reading(2, 60), threshold: 25), .insufficientData)
    }

    func testShortSpanIsInsufficient() {
        let samples = [sample(0, 60), sample(1, 59), sample(2, 58)]
        XCTAssertEqual(DrainRateCalculator.estimate(samples: samples, current: reading(3, 58), threshold: 25), .insufficientData)
    }

    func testFlatBatteryIsNotDecreasing() {
        let samples = (0..<4).map { sample(Double($0) * 5, 60) }
        XCTAssertEqual(DrainRateCalculator.estimate(samples: samples, current: reading(20, 60), threshold: 25), .notDecreasing)
    }

    func testSamplesBeforeChargingAreIgnored() {
        // Fast drain, then a charge, then a slow drain. Only the slow drain counts.
        let samples = [
            sample(0, 90), sample(10, 70), sample(20, 50),
            sample(25, 55, power: .ac, charging: true),
            sample(30, 60), sample(60, 59), sample(90, 58),
        ]
        guard case .draining(let rate, _) = DrainRateCalculator.estimate(samples: samples, current: reading(90, 58), threshold: 25) else {
            return XCTFail()
        }
        XCTAssertEqual(rate, 2, accuracy: 0.01)
    }

    func testAtThresholdHasNoETA() {
        let samples = (0..<4).map { sample(Double($0) * 10, 28 - $0) }
        guard case .draining(_, let eta) = DrainRateCalculator.estimate(samples: samples, current: reading(30, 25), threshold: 25) else {
            return XCTFail()
        }
        XCTAssertNil(eta)
    }
}

final class SampleHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ seconds: Double, _ percentage: Int) -> BatterySample {
        BatterySample(timestamp: start.addingTimeInterval(seconds), percentage: percentage, isCharging: false, powerSource: .battery)
    }

    func testUnchangedReadingIsSkippedUntilHeartbeat() {
        var history = SampleHistory.appending(sample(0, 60), to: [])
        history = SampleHistory.appending(sample(30, 60), to: history)
        XCTAssertEqual(history.count, 1)
        history = SampleHistory.appending(sample(SampleHistory.heartbeatInterval, 60), to: history)
        XCTAssertEqual(history.count, 2)
    }

    func testChangeIsRecordedImmediately() {
        let history = SampleHistory.appending(sample(30, 59), to: [sample(0, 60)])
        XCTAssertEqual(history.count, 2)
    }

    func testCapacityIsLimited() {
        var history: [BatterySample] = []
        for index in 0..<30 {
            history = SampleHistory.appending(sample(Double(index) * 30, 90 - index), to: history)
        }
        XCTAssertEqual(history.count, SampleHistory.capacity)
        XCTAssertEqual(history.last?.percentage, 61)
    }
}

final class SleepTriggerPolicyTests: XCTestCase {
    private func reading(_ percentage: Int, power: PowerSource = .battery) -> BatteryReading {
        BatteryReading(timestamp: Date(), percentage: percentage, isCharging: false, isCharged: false, powerSource: power)
    }

    private let settings = AppSettings(enabled: true, thresholdPercentage: 25)

    func testFiresAtThresholdWhenArmed() {
        XCTAssertTrue(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(25), actionTriggered: false, armed: true))
    }

    func testDoesNotFireAboveThreshold() {
        XCTAssertFalse(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(26), actionTriggered: false, armed: true))
    }

    func testDoesNotFireTwice() {
        XCTAssertFalse(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(20), actionTriggered: true, armed: true))
    }

    func testDoesNotFireOnAC() {
        XCTAssertFalse(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(20, power: .ac), actionTriggered: false, armed: true))
    }

    func testDoesNotFireWhenDisabled() {
        let disabled = AppSettings(enabled: false, thresholdPercentage: 25)
        XCTAssertFalse(SleepTriggerPolicy.shouldTrigger(settings: disabled, reading: reading(20), actionTriggered: false, armed: true))
    }

    func testWakeBelowThresholdDoesNotFireUntilRearmed() {
        var armed = false
        armed = SleepTriggerPolicy.armed(previously: armed, reading: reading(24), threshold: 25)
        XCTAssertFalse(armed)
        XCTAssertFalse(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(24), actionTriggered: false, armed: armed))

        armed = SleepTriggerPolicy.armed(previously: armed, reading: reading(30), threshold: 25)
        XCTAssertTrue(armed)
        armed = SleepTriggerPolicy.armed(previously: armed, reading: reading(25), threshold: 25)
        XCTAssertTrue(SleepTriggerPolicy.shouldTrigger(settings: settings, reading: reading(25), actionTriggered: false, armed: armed))
    }
}

final class KeepAwakePolicyTests: XCTestCase {
    private func reading(_ percentage: Int, power: PowerSource = .battery) -> BatteryReading {
        BatteryReading(timestamp: Date(), percentage: percentage, isCharging: false, isCharged: false, powerSource: power)
    }

    private let settings = AppSettings(enabled: true, thresholdPercentage: 25)

    func testAllowedAboveThreshold() {
        XCTAssertTrue(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(26)))
    }

    func testThresholdOverridesKeepAwakeOnBattery() {
        XCTAssertFalse(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(25)))
        XCTAssertFalse(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(10)))
    }

    func testAllowedBelowThresholdOnAC() {
        XCTAssertTrue(SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading(10, power: .ac)))
    }

    func testAllowedWhenGuardDisabled() {
        let disabled = AppSettings(enabled: false, thresholdPercentage: 25)
        XCTAssertTrue(SleepTriggerPolicy.allowsKeepAwake(settings: disabled, reading: reading(10)))
    }
}

final class BatteryTelemetryTests: XCTestCase {
    func testParsesAppleSiliconLayout() {
        let battery: [String: Any] = [
            "Voltage": NSNumber(value: 11_511),
            "Amperage": NSNumber(value: UInt64(18_446_744_073_709_550_429)), // -1187 mA
            "PowerTelemetryData": ["SystemLoad": NSNumber(value: 15_390)],
            "AdapterDetails": ["FamilyCode": NSNumber(value: 0)],
        ]
        let pack: [String: Any] = ["BatteryData": ["Temperature": NSNumber(value: 3559)]]
        let telemetry = BatteryTelemetry.parse(battery: battery, pack: pack)

        XCTAssertEqual(telemetry.batteryWatts!, -13.664, accuracy: 0.001)
        XCTAssertEqual(telemetry.systemWatts!, 15.39, accuracy: 0.001)
        XCTAssertEqual(telemetry.temperatureCelsius!, 35.59, accuracy: 0.001)
        XCTAssertNil(telemetry.adapterWatts)
    }

    func testParsesTopLevelTemperatureAndAdapter() {
        let battery: [String: Any] = [
            "Voltage": NSNumber(value: 12_600),
            "Amperage": NSNumber(value: 2000),
            "Temperature": NSNumber(value: 3048),
            "AdapterDetails": ["Watts": NSNumber(value: 96)],
        ]
        let telemetry = BatteryTelemetry.parse(battery: battery, pack: nil)

        XCTAssertEqual(telemetry.batteryWatts!, 25.2, accuracy: 0.001)
        XCTAssertEqual(telemetry.temperatureCelsius!, 30.48, accuracy: 0.001)
        XCTAssertEqual(telemetry.adapterWatts, 96)
        XCTAssertNil(telemetry.systemWatts)
    }

    func testParsesAdapterInputFromPowerTelemetry() {
        let battery: [String: Any] = ["PowerTelemetryData": ["SystemLoad": NSNumber(value: 18_900), "SystemPowerIn": NSNumber(value: 63_250)]]
        let telemetry = BatteryTelemetry.parse(battery: battery, pack: nil)
        XCTAssertEqual(telemetry.adapterInputWatts!, 63.25, accuracy: 0.001)

        let unplugged: [String: Any] = ["PowerTelemetryData": ["SystemLoad": NSNumber(value: 17_000), "SystemPowerIn": NSNumber(value: 0)]]
        XCTAssertNil(BatteryTelemetry.parse(battery: unplugged, pack: nil).adapterInputWatts)
    }

    func testIgnoresImplausibleTemperature() {
        let telemetry = BatteryTelemetry.parse(battery: ["Temperature": NSNumber(value: 0)], pack: nil)
        XCTAssertNil(telemetry.temperatureCelsius)
    }
}

/// Talks to the real IOKit power management on the machine running the tests.
final class SystemIntegrationTests: XCTestCase {
    func testLiveTelemetry() throws {
        guard case .success(let reading) = BatteryMonitor.readBattery() else {
            throw XCTSkip("No battery on this Mac")
        }
        print("Live reading: \(reading.percentage)% \(reading.powerDescription), \(reading.telemetry)")
        XCTAssertNotNil(reading.telemetry.batteryWatts)
    }

    @MainActor
    func testKeepAwakeAssertionIsVisibleAndReleased() throws {
        let service = KeepAwakeService()
        try service.hold(keepDisplayAwake: false)
        XCTAssertEqual(ownAssertionTypes(), ["PreventUserIdleSystemSleep"])

        try service.hold(keepDisplayAwake: true)
        XCTAssertEqual(ownAssertionTypes(), ["PreventUserIdleDisplaySleep"])

        service.release()
        XCTAssertEqual(ownAssertionTypes(), [])
    }

    private func ownAssertionTypes() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        return (all[NSNumber(value: getpid())] ?? [])
            .filter { $0["AssertName"] as? String == "Battery Sleep Guard keep awake" }
            .compactMap { $0["AssertType"] as? String }
    }
}

@MainActor
final class CPUTemperatureSensorTests: XCTestCase {
    func testPicksKeysByChipGeneration() {
        XCTAssertEqual(CPUTemperatureSensor.candidateKeys(chip: "Apple M1 Pro").first, "Tp09")
        XCTAssertTrue(CPUTemperatureSensor.candidateKeys(chip: "Apple M2").contains("Tp1h"))
        XCTAssertTrue(CPUTemperatureSensor.candidateKeys(chip: "Apple M3 Max").contains("Tf04"))
        XCTAssertTrue(CPUTemperatureSensor.candidateKeys(chip: "Apple M4 Pro").contains("Tp0V"))
        XCTAssertEqual(CPUTemperatureSensor.candidateKeys(chip: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz").first, "TC0D")
        XCTAssertEqual(CPUTemperatureSensor.candidateKeys(chip: "Apple M10"), [])
        XCTAssertEqual(CPUTemperatureSensor.candidateKeys(chip: ""), [])
    }

    func testReadsAPlausibleTemperatureOnThisMac() throws {
        let keys = CPUTemperatureSensor.candidateKeys(chip: CPUTemperatureSensor.chipName())
        try XCTSkipIf(keys.isEmpty, "No known SMC keys for this chip")
        let celsius = try XCTUnwrap(CPUTemperatureSensor().read())
        XCTAssertTrue((10...120).contains(celsius), "\(celsius)")
    }
}
