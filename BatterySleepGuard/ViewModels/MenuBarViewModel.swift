import AppKit
import Observation
import os
import ServiceManagement

@MainActor
@Observable
final class MenuBarViewModel {
    enum Status: Equatable {
        case starting
        case noBattery
        case batteryUnavailable
        case disabled
        case sleepTriggered
        case onACPower
        case waitingForRecharge
        case monitoring
    }

    private(set) var settings: AppSettings
    private(set) var reading: BatteryReading?
    private(set) var batteryError: BatteryError?
    private(set) var samples: [BatterySample]
    private(set) var monitoringStartDate: Date
    private(set) var actionTriggered: Bool
    private(set) var armed: Bool
    private(set) var sleepError: String?
    private(set) var isSleepInProgress = false
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?
    private(set) var notificationsAllowed: Bool?

    /// The user asked to keep the Mac awake. The assertion may still be suspended by the threshold.
    private(set) var keepAwakeActive = false
    private(set) var keepAwakeEndDate: Date?
    private(set) var keepAwakeHolding = false
    private(set) var keepAwakeError: String?

    @ObservationIgnored private let persistence: PersistenceService
    @ObservationIgnored private let monitor = BatteryMonitor()
    @ObservationIgnored private let sleepController = SleepController()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let loginItems = LoginItemManager()
    @ObservationIgnored private let keepAwake = KeepAwakeService()
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored let processes = ProcessEnergyMonitor()
    @ObservationIgnored private let eventLogger = Logger(subsystem: "BatterySleepGuard", category: "Events")
    @ObservationIgnored private var keepAwakeTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var earlyWarningPosted = false

    init(persistence: PersistenceService = PersistenceService(), history: HistoryStore? = nil) {
        self.persistence = persistence
        let settings = persistence.loadSettings()
        self.settings = settings
        self.history = history ?? HistoryStore(
            directory: HistoryStore.defaultDirectory,
            retention: TimeInterval(settings.historyRetentionDays) * 86_400
        )
        samples = persistence.loadSamples()
        actionTriggered = persistence.loadActionTriggered()
        armed = persistence.loadArmed()
        if let date = persistence.loadMonitoringStartDate() {
            monitoringStartDate = date
        } else {
            monitoringStartDate = Date()
            persistence.saveMonitoringStartDate(monitoringStartDate)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        logEvent(.launch, "App started")

        // The Mac slept or rebooted while the app was not running: the persisted cycle is over.
        if let lastWake = SystemClock.lastWakeOrBoot(), lastWake > monitoringStartDate {
            beginNewCycle(clearingSamples: true, reason: "Mac slept or rebooted while the app was not running")
        }

        monitor.onUpdate = { [weak self] result in self?.handle(result) }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.logEvent(.displayOff, "Display turned off") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.logEvent(.displayOn, "Display turned on") }
        })

        monitor.start()

        // Power attributable to CPU work: average load over the process window above the
        // idle floor, the lowest load seen in the last day. A day rather than an hour, so a
        // build or VM that has been running for hours does not become the floor itself.
        processes.attributableWatts = { [weak self] in
            guard let self else { return nil }
            let recent = history.entries(in: ProcessEnergyMonitor.window).compactMap(\.systemWatts)
            let lastDay = history.entries(in: 24 * 3600).compactMap(\.systemWatts)
            let average = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
            return ProcessUsageCalculator.attributableWatts(averageLoad: average, idleFloor: lastDay.min())
        }
        processes.start()

        refreshLoginItemStatus()
        notifications.configure()
        Task { notificationsAllowed = await notifications.requestAuthorization() }
    }

    private func handleWake() {
        logEvent(.wake, "System woke")
        beginNewCycle(clearingSamples: true, reason: "System wake")
        monitor.refresh()
    }

    /// Resets the one-shot trigger. The cycle re-arms on the first reading above the threshold.
    private func beginNewCycle(clearingSamples: Bool, reason: String) {
        if clearingSamples {
            samples = []
            persistence.saveSamples(samples)
        }
        monitoringStartDate = Date()
        persistence.saveMonitoringStartDate(monitoringStartDate)
        setActionTriggered(false)
        setArmed(false)
        sleepError = nil
        earlyWarningPosted = false
        logEvent(.cycleReset, reason)
    }

    // MARK: - Battery updates

    private func handle(_ result: Result<BatteryReading, BatteryError>) {
        switch result {
        case .failure(let error):
            if batteryError != error {
                logEvent(.batteryError, error.localizedDescription)
            }
            reading = nil
            batteryError = error
            syncKeepAwake()
        case .success(let newReading):
            if let event = HistoryEvent.powerSourceEvent(previous: reading?.powerSource, reading: newReading) {
                logEvent(event.kind, event.message)
                if SleepTriggerPolicy.clearsEarlyWarning(event.kind) { earlyWarningPosted = false }
            }
            reading = newReading
            batteryError = nil

            let updatedSamples = SampleHistory.appending(newReading.sample, to: samples)
            if updatedSamples != samples {
                samples = updatedSamples
                persistence.saveSamples(samples)
            }

            setArmed(SleepTriggerPolicy.armed(
                previously: armed, reading: newReading, threshold: settings.thresholdPercentage
            ))

            // Drops the keep awake assertion at or below the threshold, before sleeping.
            syncKeepAwake()

            recordHistory(newReading)
            postEarlyWarningIfDue()

            if SleepTriggerPolicy.shouldTrigger(
                settings: settings, reading: newReading, actionTriggered: actionTriggered, armed: armed
            ) {
                logEvent(.sleepTriggered, "Battery at \(newReading.percentage)%, threshold \(settings.thresholdPercentage)%")
                setActionTriggered(true)
                Task { await performSleep(notifyingAt: newReading.percentage) }
            }
        }
    }

    // MARK: - User actions

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.enabled else { return }
        settings.enabled = enabled
        persistence.save(settings)
        logEvent(enabled ? .guardEnabled : .guardDisabled, "Threshold \(settings.thresholdPercentage)%")
        if enabled {
            beginNewCycle(clearingSamples: false, reason: "Guard enabled")
            monitor.refresh()
        }
        syncKeepAwake()
    }

    func adjustThreshold(by delta: Int) {
        let newValue = AppSettings.clampedThreshold(settings.thresholdPercentage + delta)
        guard newValue != settings.thresholdPercentage else { return }
        settings.thresholdPercentage = newValue
        persistence.save(settings)
        // Raising the threshold to or above the current level must not put the Mac to sleep
        // on the spot, so arming is re-evaluated against the new value.
        setArmed((reading?.percentage ?? 0) > newValue)
        earlyWarningPosted = false
        syncKeepAwake()
    }

    func sleepNow() {
        logEvent(.sleepTriggered, "Requested by user")
        Task { await performSleep(notifyingAt: nil) }
    }

    func resetStatistics() {
        beginNewCycle(clearingSamples: true, reason: "Reset by user")
        monitor.refresh()
    }

    func setMenuBarText(_ text: MenuBarText) {
        settings.menuBarText = text
        persistence.save(settings)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            try loginItems.setEnabled(enabled)
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        loginItemStatus = loginItems.status
    }

    func openLoginItemsSettings() {
        loginItems.openSystemSettings()
    }

    func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The menu bar window is on screen: refresh faster and read the CPU temperature.
    func setMenuVisible(_ visible: Bool) {
        monitor.setLiveUpdates(visible)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func performSleep(notifyingAt percentage: Int?) async {
        guard !isSleepInProgress else { return }
        isSleepInProgress = true
        defer { isSleepInProgress = false }
        sleepError = nil

        if let percentage {
            await notifications.postSleepNotification(percentage: percentage)
            // Give the banner a moment to appear before the display goes dark.
            try? await Task.sleep(for: .seconds(2))
        }

        do {
            try await sleepController.sleepNow()
        } catch {
            sleepError = error.localizedDescription
            logEvent(.sleepFailed, error.localizedDescription)
        }
    }

    // MARK: - Keep awake

    func setKeepAwake(_ active: Bool) {
        keepAwakeActive = active
        keepAwakeEndDate = active ? settings.keepAwakeDuration.interval.map { Date().addingTimeInterval($0) } : nil
        scheduleKeepAwakeExpiry()
        syncKeepAwake()
    }

    func setKeepAwakeDuration(_ duration: KeepAwakeDuration) {
        settings.keepAwakeDuration = duration
        persistence.save(settings)
        // Picking a new duration during a session restarts the countdown from now.
        if keepAwakeActive { setKeepAwake(true) }
    }

    func setKeepAwakeOnlyOnAC(_ onlyOnAC: Bool) {
        settings.keepAwakeOnlyOnAC = onlyOnAC
        persistence.save(settings)
        syncKeepAwake()
    }

    func setEarlyWarning(_ enabled: Bool) {
        settings.earlyWarning = enabled
        persistence.save(settings)
    }

    func setHistoryRetention(days: Int) {
        guard AppSettings.retentionChoices.contains(days) else { return }
        settings.historyRetentionDays = days
        persistence.save(settings)
        history.setRetention(days: days)
    }

    func clearHistory() {
        history.clear()
    }

    /// Remaining keep awake time for a timed session, nil when off or indefinite.
    var keepAwakeRemaining: TimeInterval? {
        guard keepAwakeActive, let keepAwakeEndDate else { return nil }
        return max(0, keepAwakeEndDate.timeIntervalSinceNow)
    }

    /// Why keep awake is not holding right now although it is turned on.
    var keepAwakeSuspensionReason: String? {
        guard keepAwakeSuspended else { return nil }
        if settings.keepAwakeOnlyOnAC, reading?.isOnBattery == true { return "Suspended while on battery." }
        return "Suspended while on battery at or below \(settings.thresholdPercentage)%."
    }

    func setKeepDisplayAwake(_ keepDisplayAwake: Bool) {
        settings.keepDisplayAwake = keepDisplayAwake
        persistence.save(settings)
        syncKeepAwake()
    }

    private func scheduleKeepAwakeExpiry() {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        guard let keepAwakeEndDate else { return }
        let timer = Timer(fire: keepAwakeEndDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncKeepAwake() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAwakeTimer = timer
    }

    /// Takes or releases the assertion to match the session, its end time and the threshold.
    private func syncKeepAwake() {
        var expired = false
        if keepAwakeActive, let keepAwakeEndDate, keepAwakeEndDate <= Date() {
            keepAwakeActive = false
            self.keepAwakeEndDate = nil
            expired = true
        }

        let wasHolding = keepAwake.isHolding
        let hadError = keepAwakeError != nil
        let shouldHold = keepAwakeActive
            && SleepTriggerPolicy.allowsKeepAwake(settings: settings, reading: reading)
        if shouldHold {
            do {
                try keepAwake.hold(keepDisplayAwake: settings.keepDisplayAwake)
                keepAwakeError = nil
            } catch {
                keepAwakeError = error.localizedDescription
                if !hadError { logEvent(.keepAwakeError, error.localizedDescription) }
            }
        } else {
            keepAwake.release()
            if !keepAwakeActive { keepAwakeError = nil }
        }
        keepAwakeHolding = keepAwake.isHolding

        guard keepAwakeHolding != wasHolding else { return }
        if keepAwakeHolding {
            logEvent(.keepAwakeHeld, settings.keepDisplayAwake ? "Display and system" : "System only")
        } else if keepAwakeActive {
            let onlyOnAC = settings.keepAwakeOnlyOnAC && reading?.isOnBattery == true
            logEvent(.keepAwakeSuspended, onlyOnAC ? "On battery, keep awake only on AC" : "On battery at or below \(settings.thresholdPercentage)%")
        } else {
            logEvent(.keepAwakeReleased, expired ? "Duration elapsed" : "Turned off")
        }
    }

    // MARK: - Persisted state helpers

    private func setActionTriggered(_ value: Bool) {
        guard value != actionTriggered else { return }
        actionTriggered = value
        persistence.saveActionTriggered(value)
    }

    private func setArmed(_ value: Bool) {
        guard value != armed else { return }
        armed = value
        persistence.saveArmed(value)
    }

    // MARK: - Derived state

    var status: Status {
        if batteryError == .noBattery { return .noBattery }
        if batteryError != nil { return .batteryUnavailable }
        guard let reading else { return .starting }
        if !settings.enabled { return .disabled }
        if actionTriggered { return .sleepTriggered }
        if !reading.isOnBattery { return .onACPower }
        if !armed { return .waitingForRecharge }
        return .monitoring
    }

    var keepAwakeSuspended: Bool { keepAwakeActive && !keepAwakeHolding && keepAwakeError == nil }

    var drainEstimate: DrainEstimate {
        DrainRateCalculator.estimate(samples: samples, current: reading, threshold: settings.thresholdPercentage)
    }

    /// When the guard is expected to fire, if it is armed and the battery is draining.
    var estimatedSleepDate: Date? {
        guard status == .monitoring, let reading,
              case .draining(_, let timeToThreshold?) = drainEstimate
        else { return nil }
        return reading.timestamp.addingTimeInterval(timeToThreshold)
    }

    /// The system menu bar already shows the battery level, so this shows the guard's state.
    var menuBarSymbol: String {
        if keepAwakeHolding { return "cup.and.heat.waves.fill" }
        switch status {
        case .noBattery, .batteryUnavailable: return "exclamationmark.triangle"
        case .monitoring: return "moon.zzz.fill"
        case .disabled: return "moon"
        case .starting, .sleepTriggered, .onACPower, .waitingForRecharge: return "moon.zzz"
        }
    }

    var menuBarText: String? {
        switch settings.menuBarText {
        case .none:
            return nil
        case .timeToSleep:
            return estimatedSleepDate.map { Formatting.duration($0.timeIntervalSinceNow) }
        case .batteryAndTimeToSleep:
            guard let reading else { return nil }
            let eta = estimatedSleepDate.map { Formatting.duration($0.timeIntervalSinceNow) }
            return eta.map { "\(reading.percentage)%  \($0)" } ?? "\(reading.percentage)%"
        case .keepAwakeRemaining:
            guard keepAwakeActive else { return nil }
            return keepAwakeRemaining.map(Formatting.duration) ?? "on"
        case .batteryPower:
            return reading?.telemetry.batteryWatts.map { Formatting.watts(abs($0)) }
        case .temperature:
            return reading?.telemetry.temperatureCelsius.map(Formatting.temperature)
        }
    }

    var canSleep: Bool { !isSleepInProgress }

    /// "ghostty 120%, Safari 8%": the two busiest applications of the last minutes.
    var topProcessesSummary: String? {
        let top = processes.groups.prefix(2)
        guard !top.isEmpty else { return nil }
        return top.map { "\($0.name) \(Int($0.cpuPercent.rounded()))%" }.joined(separator: ", ")
    }

    // MARK: - History

    /// Writes the event to the events file and to the unified log, where it survives at
    /// notice level: `/usr/bin/log show --predicate 'subsystem == "BatterySleepGuard"'`.
    private func logEvent(_ kind: HistoryEvent.Kind, _ message: String) {
        eventLogger.notice("\(kind.rawValue, privacy: .public): \(message, privacy: .public)")
        history.record(HistoryEvent(timestamp: Date(), kind: kind, message: message))
    }

    /// Posts one notification per cycle when the guard is expected to fire within the lead time.
    private func postEarlyWarningIfDue() {
        guard settings.earlyWarning, status == .monitoring, let date = estimatedSleepDate,
              SleepTriggerPolicy.shouldWarn(
                  estimatedSleepDate: date, now: Date(),
                  leadTime: AppSettings.earlyWarningLeadTime, alreadyWarned: earlyWarningPosted
              )
        else { return }
        earlyWarningPosted = true
        let minutes = max(1, Int((date.timeIntervalSinceNow / 60).rounded()))
        logEvent(.earlyWarning, "Sleep expected in \(minutes) min, at \(date.formatted(date: .omitted, time: .shortened))")
        Task { await notifications.postEarlyWarning(minutes: minutes, at: date, threshold: settings.thresholdPercentage) }
    }

    private func recordHistory(_ reading: BatteryReading) {
        history.record(HistoryEntry(
            reading: reading,
            estimate: drainEstimate,
            keepAwakeHolding: keepAwakeHolding,
            status: String(describing: status)
        ))
    }
}
