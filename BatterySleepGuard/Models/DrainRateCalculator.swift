import Foundation

enum DrainEstimate: Equatable {
    /// No battery reading is available.
    case unavailable
    /// The Mac is on AC power or charging, so there is nothing to estimate.
    case notOnBattery
    /// Not enough discharging samples yet.
    case insufficientData
    /// On battery, but the level is flat or rising.
    case notDecreasing
    /// `timeToThreshold` is nil when the battery is already at or below the threshold.
    case draining(percentPerHour: Double, timeToThreshold: TimeInterval?)
}

/// Least squares slope over the most recent uninterrupted discharge, which acts as a
/// moving average of the drain rate across the stored samples.
enum DrainRateCalculator {
    static let minimumPoints = 3
    static let minimumSpan: TimeInterval = 5 * 60
    static let minimumRate = 0.1

    static func estimate(samples: [BatterySample], current: BatteryReading?, threshold: Int) -> DrainEstimate {
        guard let current else { return .unavailable }
        guard current.isOnBattery, !current.isCharging else { return .notOnBattery }

        // Only the trailing run of discharging samples counts; anything before the last
        // charge or AC period describes a different discharge.
        var points = Array(samples.reversed().prefix(while: \.isDischarging).reversed())
        if points.last.map({ current.timestamp > $0.timestamp }) ?? true {
            points.append(current.sample)
        }

        guard points.count >= minimumPoints,
              let first = points.first, let last = points.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan,
              let slope = slopePerSecond(points)
        else { return .insufficientData }

        let percentPerHour = -slope * 3600
        guard percentPerHour >= minimumRate else { return .notDecreasing }

        let remaining = Double(current.percentage - threshold)
        let timeToThreshold = remaining > 0 ? remaining / percentPerHour * 3600 : nil
        return .draining(percentPerHour: percentPerHour, timeToThreshold: timeToThreshold)
    }

    private static func slopePerSecond(_ points: [BatterySample]) -> Double? {
        let origin = points[0].timestamp
        let xs = points.map { $0.timestamp.timeIntervalSince(origin) }
        let ys = points.map { Double($0.percentage) }
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        return variance > 0 ? covariance / variance : nil
    }
}
