import Foundation

/// Decides when the guard puts the Mac to sleep.
///
/// The guard fires when the battery drops to the threshold, not merely while it is below it.
/// A cycle is "armed" only after the battery has been seen above the threshold. Without this,
/// waking a Mac that is already at or below the threshold would send it straight back to sleep
/// on the next check, leaving no time to plug in the charger.
enum SleepTriggerPolicy {
    static func shouldTrigger(
        settings: AppSettings,
        reading: BatteryReading,
        actionTriggered: Bool,
        armed: Bool
    ) -> Bool {
        settings.enabled
            && reading.isOnBattery
            && reading.percentage <= settings.thresholdPercentage
            && !actionTriggered
            && armed
    }

    /// Arming is sticky within a cycle: once the battery was above the threshold, it stays armed.
    static func armed(previously armed: Bool, reading: BatteryReading, threshold: Int) -> Bool {
        armed || reading.percentage > threshold
    }

    /// The threshold always wins over keep awake. While the guard is enabled and the Mac is on
    /// battery at or below the threshold, the keep awake assertion is released, so the forced
    /// sleep goes through and, if the guard is paused after a wake, normal idle sleep works too.
    static func allowsKeepAwake(settings: AppSettings, reading: BatteryReading?) -> Bool {
        guard let reading else { return true }
        if settings.keepAwakeOnlyOnAC, reading.isOnBattery { return false }
        guard settings.enabled else { return true }
        return !(reading.isOnBattery && reading.percentage <= settings.thresholdPercentage)
    }

    /// Plugging in starts a recharge, after which the next approach to the threshold deserves
    /// its own warning even though the cycle (and its arming) continues.
    static func clearsEarlyWarning(_ kind: HistoryEvent.Kind) -> Bool {
        kind == .pluggedIn
    }

    /// One early warning per cycle, once the estimated sleep time is within `leadTime` and
    /// still ahead; a time already passed means the sleep itself is about to happen.
    static func shouldWarn(estimatedSleepDate: Date?, now: Date, leadTime: TimeInterval, alreadyWarned: Bool) -> Bool {
        guard !alreadyWarned, let estimatedSleepDate else { return false }
        let remaining = estimatedSleepDate.timeIntervalSince(now)
        return remaining > 0 && remaining <= leadTime
    }
}
