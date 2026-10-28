import Foundation

enum KeepAwakeDuration: Int, CaseIterable, Identifiable, Sendable {
    case indefinitely = 0
    case minutes30 = 30
    case hour1 = 60
    case hours2 = 120
    case hours4 = 240
    case hours8 = 480

    var id: Int { rawValue }

    var interval: TimeInterval? {
        self == .indefinitely ? nil : TimeInterval(rawValue * 60)
    }

    var label: String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours4: return "4 hours"
        case .hours8: return "8 hours"
        }
    }
}

/// Optional text shown next to the status icon in the menu bar.
enum MenuBarText: String, CaseIterable, Identifiable, Sendable {
    case none
    case timeToSleep
    case batteryAndTimeToSleep
    case keepAwakeRemaining
    case batteryPower
    case temperature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Icon only"
        case .timeToSleep: return "Time until sleep"
        case .batteryAndTimeToSleep: return "Battery and time until sleep"
        case .keepAwakeRemaining: return "Keep awake remaining"
        case .batteryPower: return "Battery power"
        case .temperature: return "Battery temperature"
        }
    }
}

struct AppSettings: Equatable, Sendable {
    static let defaultThreshold = 25
    static let thresholdRange = 5...95
    static let retentionChoices = [1, 7, 30]
    /// How long before the estimated sleep time the early warning is posted.
    static let earlyWarningLeadTime: TimeInterval = 10 * 60

    var enabled = true
    var thresholdPercentage = AppSettings.defaultThreshold
    var keepDisplayAwake = false
    var keepAwakeDuration = KeepAwakeDuration.indefinitely
    /// Keep awake is suspended while on battery, so a forgotten session cannot drain it.
    var keepAwakeOnlyOnAC = false
    var menuBarText = MenuBarText.none
    var historyRetentionDays = 7
    /// Notify about 10 minutes before the guard is expected to put the Mac to sleep.
    var earlyWarning = true

    static func clampedThreshold(_ value: Int) -> Int {
        min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }
}
