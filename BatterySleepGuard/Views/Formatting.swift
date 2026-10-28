import Foundation

enum Formatting {
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return totalMinutes == 0 ? "<1m" : "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.1f W", value)
    }

    /// Follows the user's locale, so it shows Fahrenheit where that is the norm.
    static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// "13.4 W out" while discharging, "22.0 W in" while charging.
    static func batteryFlow(_ watts: Double) -> String {
        if abs(watts) < 0.05 { return "0 W" }
        return "\(Self.watts(abs(watts))) \(watts < 0 ? "out" : "in")"
    }

    /// "17.2 W out, discharging", "44.0 W in, charging" or "Idle".
    static func batteryState(_ watts: Double) -> String {
        if abs(watts) < 0.05 { return "Idle" }
        return "\(batteryFlow(watts)), \(watts < 0 ? "discharging" : "charging")"
    }
}
