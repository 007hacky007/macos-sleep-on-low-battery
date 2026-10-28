import Foundation

enum PowerSource: String, Codable, Sendable {
    case battery
    case ac
    case unknown
}

/// One point in the battery history used for the drain rate calculation.
struct BatterySample: Codable, Equatable, Sendable {
    let timestamp: Date
    let percentage: Int
    let isCharging: Bool
    let powerSource: PowerSource

    var isDischarging: Bool { powerSource == .battery && !isCharging }
}

/// Live snapshot of the internal battery as reported by IOKit.
struct BatteryReading: Equatable, Sendable {
    let timestamp: Date
    let percentage: Int
    let isCharging: Bool
    let isCharged: Bool
    let powerSource: PowerSource
    var telemetry = BatteryTelemetry()

    var isOnBattery: Bool { powerSource == .battery }

    var sample: BatterySample {
        BatterySample(timestamp: timestamp, percentage: percentage, isCharging: isCharging, powerSource: powerSource)
    }

    var powerDescription: String {
        switch powerSource {
        case .battery: return "Battery"
        case .ac where isCharging: return "Charging"
        case .ac where isCharged: return "AC power (charged)"
        case .ac: return "AC power (not charging)"
        case .unknown: return "Unknown"
        }
    }
}

/// Rolling window of the most recent samples.
///
/// The battery only reports whole percents, so 20 consecutive 30 second samples would cover
/// just 10 minutes and often a single 1% step. A sample is therefore stored only when the
/// percentage or power state changes, or as a heartbeat every few minutes. That keeps the
/// window at 20 entries while it spans enough time for a stable moving average.
enum SampleHistory {
    static let capacity = 20
    static let heartbeatInterval: TimeInterval = 5 * 60

    static func appending(_ sample: BatterySample, to samples: [BatterySample]) -> [BatterySample] {
        if let last = samples.last {
            let changed = last.percentage != sample.percentage
                || last.isCharging != sample.isCharging
                || last.powerSource != sample.powerSource
            let heartbeatDue = sample.timestamp.timeIntervalSince(last.timestamp) >= heartbeatInterval
            guard changed || heartbeatDue else { return samples }
        }
        return Array((samples + [sample]).suffix(capacity))
    }
}
