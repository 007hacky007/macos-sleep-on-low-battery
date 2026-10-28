import Foundation

struct PersistenceService {
    enum Key {
        static let enabled = "enabled"
        static let thresholdPercentage = "thresholdPercentage"
        static let monitoringStartDate = "monitoringStartDate"
        static let samples = "samples"
        static let actionTriggered = "actionTriggered"
        static let armed = "armed"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let keepAwakeDuration = "keepAwakeDuration"
        static let menuBarText = "menuBarText"
        static let keepAwakeOnlyOnAC = "keepAwakeOnlyOnAC"
        static let historyRetentionDays = "historyRetentionDays"
        static let earlyWarning = "earlyWarning"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSettings() -> AppSettings {
        var settings = AppSettings()
        if defaults.object(forKey: Key.enabled) != nil {
            settings.enabled = defaults.bool(forKey: Key.enabled)
        }
        if defaults.object(forKey: Key.thresholdPercentage) != nil {
            settings.thresholdPercentage = AppSettings.clampedThreshold(defaults.integer(forKey: Key.thresholdPercentage))
        }
        settings.keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        if let duration = KeepAwakeDuration(rawValue: defaults.integer(forKey: Key.keepAwakeDuration)) {
            settings.keepAwakeDuration = duration
        }
        if let text = defaults.string(forKey: Key.menuBarText).flatMap(MenuBarText.init(rawValue:)) {
            settings.menuBarText = text
        }
        settings.keepAwakeOnlyOnAC = defaults.bool(forKey: Key.keepAwakeOnlyOnAC)
        if AppSettings.retentionChoices.contains(defaults.integer(forKey: Key.historyRetentionDays)) {
            settings.historyRetentionDays = defaults.integer(forKey: Key.historyRetentionDays)
        }
        if defaults.object(forKey: Key.earlyWarning) != nil {
            settings.earlyWarning = defaults.bool(forKey: Key.earlyWarning)
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.enabled, forKey: Key.enabled)
        defaults.set(settings.thresholdPercentage, forKey: Key.thresholdPercentage)
        defaults.set(settings.keepDisplayAwake, forKey: Key.keepDisplayAwake)
        defaults.set(settings.keepAwakeDuration.rawValue, forKey: Key.keepAwakeDuration)
        defaults.set(settings.menuBarText.rawValue, forKey: Key.menuBarText)
        defaults.set(settings.keepAwakeOnlyOnAC, forKey: Key.keepAwakeOnlyOnAC)
        defaults.set(settings.historyRetentionDays, forKey: Key.historyRetentionDays)
        defaults.set(settings.earlyWarning, forKey: Key.earlyWarning)
    }

    func loadMonitoringStartDate() -> Date? {
        defaults.object(forKey: Key.monitoringStartDate) as? Date
    }

    func saveMonitoringStartDate(_ date: Date) {
        defaults.set(date, forKey: Key.monitoringStartDate)
    }

    func loadSamples() -> [BatterySample] {
        guard let data = defaults.data(forKey: Key.samples) else { return [] }
        return (try? JSONDecoder().decode([BatterySample].self, from: data)) ?? []
    }

    func saveSamples(_ samples: [BatterySample]) {
        defaults.set(try? JSONEncoder().encode(samples), forKey: Key.samples)
    }

    func loadActionTriggered() -> Bool {
        defaults.bool(forKey: Key.actionTriggered)
    }

    func saveActionTriggered(_ value: Bool) {
        defaults.set(value, forKey: Key.actionTriggered)
    }

    func loadArmed() -> Bool {
        defaults.bool(forKey: Key.armed)
    }

    func saveArmed(_ value: Bool) {
        defaults.set(value, forKey: Key.armed)
    }
}
