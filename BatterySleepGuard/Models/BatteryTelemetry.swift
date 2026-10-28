import Foundation

/// Electrical and thermal details from the battery driver. Every field is optional because
/// the available keys differ between Mac models and macOS versions.
struct BatteryTelemetry: Equatable, Sendable {
    /// Power flowing into (positive, charging) or out of (negative, discharging) the battery.
    var batteryWatts: Double?
    /// Total power the Mac consumes, from battery and adapter combined.
    var systemWatts: Double?
    var temperatureCelsius: Double?
    /// Rated power of the connected adapter.
    var adapterWatts: Int?
    /// Power actually drawn from the adapter right now; nil when unplugged or not reported.
    var adapterInputWatts: Double?
    /// Average CPU core temperature from the SMC, only read while the menu bar window is open.
    var cpuTemperatureCelsius: Double?
}

extension BatteryTelemetry {
    private static let plausibleTemperature = -20.0...100.0

    /// Builds telemetry from the IORegistry properties of `AppleSmartBattery` and, when
    /// present, its `AppleSmartBatteryPack` child.
    static func parse(battery: [String: Any], pack: [String: Any]?) -> BatteryTelemetry {
        var telemetry = BatteryTelemetry()

        // mV * mA. Amperage is signed but some drivers publish it as an unsigned 64 bit value.
        if let millivolts = number(battery["Voltage"]), let milliamps = number(battery["Amperage"]) {
            telemetry.batteryWatts = millivolts * milliamps / 1_000_000
        }

        if let powerData = battery["PowerTelemetryData"] as? [String: Any] {
            if let milliwatts = number(powerData["SystemLoad"]), milliwatts > 0 {
                telemetry.systemWatts = milliwatts / 1000
            }
            if let milliwatts = number(powerData["SystemPowerIn"]), milliwatts > 0 {
                telemetry.adapterInputWatts = milliwatts / 1000
            }
        }

        // Hundredths of a degree Celsius. Older Macs publish it at the top level, Apple Silicon
        // on newer macOS only inside BatteryData of the battery or the pack.
        let candidates: [Any?] = [
            battery["Temperature"],
            (pack?["BatteryData"] as? [String: Any])?["Temperature"],
            (battery["BatteryData"] as? [String: Any])?["Temperature"],
            battery["VirtualTemperature"],
        ]
        telemetry.temperatureCelsius = candidates.lazy
            .compactMap { number($0).map { $0 / 100 } }
            .first { $0 != 0 && plausibleTemperature.contains($0) }

        if let adapter = battery["AdapterDetails"] as? [String: Any],
           let watts = number(adapter["Watts"]), watts > 0 {
            telemetry.adapterWatts = Int(watts)
        }

        return telemetry
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // int64Value reinterprets an unsigned 64 bit two's complement value as signed.
        return Double(number.int64Value)
    }
}
